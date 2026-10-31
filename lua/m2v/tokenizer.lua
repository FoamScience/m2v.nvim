-- The two HF tokenizer flavours potion models use:
-- WordPiece: BertNormalizer (lowercase) + BertPreTokenizer + WordPiece
-- Unigram: Precompiled charsmap + punctuation/whitespace Replace + Strip, Metaspace, Unigram Viterbi
local ffi = require("ffi")

ffi.cdef([[
    typedef ptrdiff_t utf8proc_ssize_t;
    utf8proc_ssize_t utf8proc_map(const uint8_t *str, utf8proc_ssize_t strlen, uint8_t **dstptr, int options);
    utf8proc_ssize_t utf8proc_iterate(const uint8_t *str, utf8proc_ssize_t strlen, int32_t *codepoint_ref);
    bool utf8proc_grapheme_break_stateful(int32_t codepoint1, int32_t codepoint2, int32_t *state);
    void free(void *ptr);
]])

-- utf8proc ships inside nvim; NULLTERM | STABLE | DECOMPOSE | STRIPMARK
local STRIP_ACCENTS = bit.bor(1, 2, 16, 8192)

local M = {}
M.__index = M

-- HF strips accents whenever it lowercases: NFD, then drop marks
local function lower_ascii_or_unicode(text)
    if not text:find("[\128-\255]") then
        return text:lower()
    end
    local dst = ffi.new("uint8_t*[1]")
    local n = ffi.C.utf8proc_map(vim.fn.tolower(text), 0, dst, STRIP_ACCENTS)
    if n < 0 then
        return vim.fn.tolower(text)
    end
    local out = ffi.string(dst[0], n)
    ffi.C.free(dst[0])
    return out
end

local Unigram = {}
Unigram.__index = Unigram

function M.load(path)
    local f = assert(io.open(path, "rb"))
    local spec = vim.json.decode(f:read("*a"))
    f:close()
    local model = spec.model
    if model.type == "Unigram" then
        return Unigram.load(spec)
    end
    assert(model.type == "WordPiece", "m2v: unsupported tokenizer model " .. tostring(model.type))
    local norm = spec.normalizer or {}
    local longest = 0
    for token in pairs(model.vocab) do
        longest = math.max(longest, #token)
    end
    return setmetatable({
        vocab = model.vocab,
        longest = longest,
        memo = {},
        memo_size = 0,
        unk = model.vocab[model.unk_token],
        prefix = model.continuing_subword_prefix or "##",
        max_word = model.max_input_chars_per_word or 100,
        lowercase = norm.lowercase ~= false,
    }, M)
end

function M:pieces(word)
    if #word > self.max_word then
        return false
    end
    local vocab, start, pieces = self.vocab, 1, {}
    while start <= #word do
        local id, stop
        for e = math.min(#word, start + self.longest - 1), start, -1 do
            local piece = word:sub(start, e)
            id = vocab[start > 1 and self.prefix .. piece or piece]
            if id then
                stop = e
                break
            end
        end
        -- HF maps the whole word to [UNK] when any part fails
        if not id then
            return false
        end
        pieces[#pieces + 1] = id
        start = stop + 1
    end
    return pieces
end

function M:wordpiece(word, out)
    local pieces = self.memo[word]
    if pieces == nil then
        if self.memo_size >= 200000 then
            self.memo, self.memo_size = {}, 0
        end
        pieces = self:pieces(word)
        self.memo[word], self.memo_size = pieces, self.memo_size + 1
    end
    if pieces then
        local n = #out
        for i = 1, #pieces do
            out[n + i] = pieces[i]
        end
    end
end

-- ids without [UNK], as model2vec drops them before pooling
function M:encode(text, max_tokens)
    text = text:gsub("%c", " ")
    if self.lowercase then
        text = lower_ascii_or_unicode(text)
    end
    -- every ASCII punctuation char is its own word; non-ASCII bytes count as word chars
    text = text:gsub("%p", " %0 ")
    local out = {}
    for word in text:gmatch("%S+") do
        self:wordpiece(word, out)
        if max_tokens and #out >= max_tokens then
            break
        end
    end
    return max_tokens and vim.list_slice(out, 1, max_tokens) or out
end

-- sentencepiece's precompiled normalizer: a darts double-array trie over UTF-8 keys whose
-- values index a blob of NUL-terminated replacements (spm_precompiled crate semantics)
local function charsmap(b64)
    local blob = vim.base64.decode(b64)
    local units = ffi.cast("const uint32_t*", blob)
    local trie_size = tonumber(units[0]) / 4
    local trie = units + 1
    local normalized = blob:sub(5 + trie_size * 4)
    local memo = {}
    local function lookup(chunk)
        local pos = 0
        local unit = trie[0]
        pos = bit.bxor(pos, bit.lshift(bit.rshift(unit, 10), bit.rshift(bit.band(unit, 0x200), 6)))
        for i = 1, #chunk do
            local c = chunk:byte(i)
            if c == 0 then
                return
            end
            pos = bit.bxor(pos, c)
            if pos < 0 or pos >= trie_size then
                return
            end
            unit = trie[pos]
            if bit.band(unit, 0x800000ff) ~= c then
                return
            end
            pos = bit.bxor(pos, bit.lshift(bit.rshift(unit, 10), bit.rshift(bit.band(unit, 0x200), 6)))
            if bit.band(bit.rshift(unit, 8), 1) == 1 then
                -- first (shortest) match wins
                local index = bit.band(trie[pos], 0x7fffffff) + 1
                local stop = normalized:find("\0", index, true)
                return normalized:sub(index, stop and stop - 1 or nil)
            end
        end
    end
    return {
        blob = blob,
        transform = function(chunk)
            local r = memo[chunk]
            if r == nil then
                r = lookup(chunk) or false
                memo[chunk] = r
            end
            return r
        end,
    }
end

local function charlen(b)
    return b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
end

-- graphemes shorter than 6 bytes are looked up whole, everything else char by char
local function precompiled_normalize(map, text)
    local out, n = {}, #text
    local str = ffi.cast("const uint8_t*", text)
    local cp, state = ffi.new("int32_t[1]"), ffi.new("int32_t[1]")
    local function emit(chunk)
        local r = map.transform(chunk)
        out[#out + 1] = r or chunk
    end
    local function grapheme(s, e)
        local g = text:sub(s, e)
        if #g < 6 then
            local r = map.transform(g)
            if r then
                out[#out + 1] = r
                return
            end
        end
        local i = s
        while i <= e do
            local l = charlen(g:byte(i - s + 1))
            emit(text:sub(i, i + l - 1))
            i = i + l
        end
    end
    local pos, start, prev = 0, 1, nil
    while pos < n do
        local l = ffi.C.utf8proc_iterate(str + pos, n - pos, cp)
        if l < 0 then
            l = 1
        end
        if prev and ffi.C.utf8proc_grapheme_break_stateful(prev, cp[0], state) then
            grapheme(start, pos)
            start = pos + 1
        end
        prev = cp[0]
        pos = pos + tonumber(l)
    end
    if start <= n then
        grapheme(start, n)
    end
    return table.concat(out)
end

-- Rust regex \s beyond ASCII: U+0085 U+00A0 U+1680 U+2000-200A U+2028 U+2029 U+202F U+205F U+3000
local UNICODE_SPACE = {}
for _, cp in ipairs({ 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }) do
    UNICODE_SPACE[vim.fn.nr2char(cp, true)] = true
end
for cp = 0x2000, 0x200A do
    UNICODE_SPACE[vim.fn.nr2char(cp, true)] = true
end

function Unigram.load(spec)
    local model = spec.model
    local ids, scores, min_score, longest = {}, ffi.new("double[?]", #model.vocab), math.huge, 0
    for i, entry in ipairs(model.vocab) do
        ids[entry[1]] = i - 1
        scores[i - 1] = entry[2]
        min_score = math.min(min_score, entry[2])
        longest = math.max(longest, #entry[1])
    end
    local map
    local function walk(norm)
        if norm.type == "Sequence" then
            for _, n in ipairs(norm.normalizers) do
                walk(n)
            end
        elseif norm.type == "Precompiled" then
            map = charsmap(norm.precompiled_charsmap)
        else
            -- Replace (ASCII punctuation spacing, whitespace collapsing) and Strip are hardcoded in encode
            assert(norm.type == "Replace" or norm.type == "Strip", "m2v: unsupported normalizer " .. norm.type)
        end
    end
    walk(spec.normalizer)
    local pre = spec.pre_tokenizer
    assert(pre.type == "Metaspace" and pre.split == false, "m2v: unsupported pre-tokenizer")
    -- special added tokens are cut out of the raw text before normalization
    local special = {}
    for _, a in ipairs(spec.added_tokens or {}) do
        if a.special then
            special[#special + 1] = a.content
        end
    end
    return setmetatable({
        ids = ids,
        special = special,
        scores = scores,
        unk_score = min_score - 10,
        unk = model.unk_id,
        longest = longest,
        map = map,
        meta = pre.replacement,
        memo = {},
        memo_size = 0,
    }, Unigram)
end

-- Viterbi over one "▁word" unit (no vocab piece contains ▁ past its first byte, so units are
-- independent); returns ids in order without [UNK]
function Unigram:viterbi(unit)
    local ids, scores, longest, n = self.ids, self.scores, self.longest, #unit
    local best_score, best_start, best_id = { [0] = 0 }, {}, {}
    local pos = 0
    while pos < n do
        local till = best_score[pos]
        local mblen = charlen(unit:byte(pos + 1))
        local single = false
        local e = pos
        while e < n do
            e = e + charlen(unit:byte(e + 1))
            if e - pos > longest then
                break
            end
            local id = ids[unit:sub(pos + 1, e)]
            if id then
                local cand = scores[id] + till
                if best_start[e] == nil or cand > best_score[e] then
                    best_score[e], best_start[e], best_id[e] = cand, pos, id
                end
                if e - pos == mblen then
                    single = true
                end
            end
        end
        if not single then
            local e2 = pos + mblen
            local cand = self.unk_score + till
            if best_start[e2] == nil or cand > best_score[e2] then
                best_score[e2], best_start[e2], best_id[e2] = cand, pos, self.unk
            end
        end
        pos = pos + mblen
    end
    local rev, e = {}, n
    while e > 0 do
        if best_id[e] ~= self.unk then
            rev[#rev + 1] = best_id[e]
        end
        e = best_start[e]
    end
    local out = {}
    for i = #rev, 1, -1 do
        out[#out + 1] = rev[i]
    end
    return out
end

function Unigram:segment(text, out, max_tokens)
    text = precompiled_normalize(self.map, text)
    text = text:gsub("%p", " %0 ")
    text = text:gsub("[\194\225\226\227][\128-\191][\128-\191]?", function(ch)
        return UNICODE_SPACE[ch] and " " or ch
    end)
    text = vim.trim(text:gsub("%s+", " "))
    local meta = self.meta
    -- Metaspace with prepend_scheme = always: every word becomes one ▁-prefixed unit
    for word in text:gmatch("%S+") do
        local unit = meta .. word
        local pieces = self.memo[unit]
        if pieces == nil then
            if self.memo_size >= 200000 then
                self.memo, self.memo_size = {}, 0
            end
            pieces = self:viterbi(unit)
            self.memo[unit], self.memo_size = pieces, self.memo_size + 1
        end
        local n = #out
        for i = 1, #pieces do
            out[n + i] = pieces[i]
        end
        if max_tokens and #out >= max_tokens then
            return
        end
    end
end

function Unigram:encode(text, max_tokens)
    local out, start = {}, 1
    while start <= #text and not (max_tokens and #out >= max_tokens) do
        local s, e, id
        for _, tok in ipairs(self.special) do
            local a, b = text:find(tok, start, true)
            if a and (not s or a < s or (a == s and b > e)) then
                s, e, id = a, b, self.ids[tok]
            end
        end
        self:segment(text:sub(start, s and s - 1 or #text), out, max_tokens)
        if not s then
            break
        end
        if id ~= self.unk then
            out[#out + 1] = id
        end
        start = e + 1
    end
    return max_tokens and vim.list_slice(out, 1, max_tokens) or out
end

return M
