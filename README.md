# m2v

> This has originally evolved from trying to use [](sgrep) as a "search by meaning tool".
> Which worked fine until I needed the "library part" to couple with other (MCP, LSP, ... etc) tools.

Semantic code search on [model2vec](https://github.com/MinishLab/model2vec) static embeddings, running entirely inside Neovim (LuaJIT FFI, treesitter, utf8proc bundled with nvim). No Python.

- `lua/m2v/tokenizer.lua`: BERT WordPiece (BertNormalizer + BertPreTokenizer) for the potion-base/code models; Unigram (sentencepiece precompiled charsmap + Metaspace + Viterbi) for potion-multilingual
- `lua/m2v/model.lua`: safetensors loader (mmap, F16/F32), mean pooling with model2vec token mapping/weights when present, L2 normalization
- `lua/m2v/chunk.lua`: treesitter chunking (top-level nodes, split when too big, small neighbours merged), line windows as fallback
- `lua/m2v/index.lua`, `indexer.lua`: per-root index built by a background `nvim -l`, incremental by mtime/size; files to embed are sharded across `opts.workers` child processes and merged back into one index
- `lua/m2v/init.lua`: model lookup/download, search = brute-force cosine fused with `rg` matches (reciprocal rank fusion)
- `lua/m2v/picker.lua`: [snacks.nvim](https://github.com/folke/snacks.nvim) pickers
- `lua/m2v/health.lua`: `:checkhealth m2v`

## Requirements

- Neovim built with LuaJIT (utf8proc is reached through FFI from the nvim binary); tested on 0.12.6
- `rg` (file listing and lexical ranking; `git ls-files` is the listing fallback)
- `curl` for the one-time model download
- snacks.nvim for the pickers only

## Install

lazy.nvim:

```lua
{
    "<owner>/m2v.nvim",
    main = "m2v",
    opts = {},
    keys = {
        { "<leader>fS", function() require("m2v.picker").search_prompt() end, desc = "Semantic search" },
        { "<leader>fL", function() require("m2v.picker").live() end, desc = "Semantic search (live)" },
    },
}
```

Only directories with a root marker (`.git` by default) are indexed. Indexes live in `stdpath("cache")/m2v/index/` and are rebuilt incrementally in the background on first search and after writes.

## Configuration

Defaults:

```lua
opts = {
    model = "minishlab/potion-code-16M-v2",
    max_tokens = 512,
    max_file_bytes = 256 * 1024,
    chunk = { max_lines = 60, target_lines = 30 },
    root_markers = { ".git" },
    rrf_k = 60, -- reciprocal rank fusion constant
    depth = 100, -- candidates taken from each ranking before fusion
    lexical = { max_terms = 16, min_len = 3, max_count = 20 },
    rebuild_delay_ms = 2000,
    workers = math.min(4, #vim.uv.cpu_info()), -- indexer processes for a full index; 1 = embed in the single indexer process
    picker = {
        n = 30,
        min_live_words = 3,
        test_patterns = { ... }, -- hidden unless the query mentions test or spec
    },
}
```

Indexing with `workers > 1` starts the indexer as a coordinator that lists files, reuses unchanged chunks from the previous index, shards the remaining files by size across up to `workers` child `nvim -l` processes (each loading the model, about 300 MB peak RSS for potion-code-16M-v2), and merges their output in file order. Fewer than 32 changed files per worker reduce the worker count, so an incremental rebuild after a few saves still embeds in the coordinator itself. The resulting `vectors.bin` is byte-identical for any worker count.

## API

```lua
local m2v = require("m2v")
local root = m2v.root(vim.api.nvim_get_current_buf()) -- nil outside a project
-- hits: { path, start, end, score }, 1-based inclusive lines, best first
local job = m2v.search(root, "parse json responses", 10, function(hits) end)
-- job:kill() cancels the ripgrep half
```

## Models

Set `opts.model`. Models are taken from `~/.cache/huggingface/hub` when present, otherwise downloaded to `stdpath("cache")/m2v/models/`. Each model gets its own index.

Supported: WordPiece and Unigram (Metaspace, `split = false`) tokenizers; `embeddings` tensor (F16 or F32), optionally with the `mapping` (I64) and `weights` (F64) tensors that model2vec vocabulary quantization adds (row = `embeddings[mapping[id]] * weights[id]`, then mean).

| model | dim | tokenizer | tensors | status |
|---|---|---|---|---|
| potion-base-2M | 64 | WordPiece | `embeddings` F32 | works |
| potion-base-4M | 128 | WordPiece | `embeddings` F32 | works |
| potion-base-8M | 256 | WordPiece | `embeddings` F32 | works |
| potion-base-32M | 512 | WordPiece | `embeddings` F32 | works |
| potion-retrieval-32M | 512 | WordPiece | `embeddings` F32 | works |
| potion-code-16M-v2 (default) | 256 | WordPiece | `embeddings` F16 | works |
| potion-code-16M | 256 | WordPiece | `embeddings` F32 + `mapping` I64 + `weights` F64 | works |
| potion-multilingual-128M | 256 | Unigram | `embeddings` F32 (500353 × 256, 512 MB) | works |

## Benchmarks

Machine: Intel i5-11600KF (12 threads), 45 GB RAM, NVIM v0.12.6 (LuaJIT 2.1). Everything below was measured 2026-10-30 on the current code, from headless `nvim -l` scripts with all models already on disk. Corpus: mini.nvim @ a03ad89, 3106 files (`rg --files`), 10416 chunks.

### Correctness

Token ids against HF `tokenizers` 0.23.3, `[UNK]` dropped as model2vec does:

- WordPiece (`potion-code-16M-v2`), 6 sample lines (Lua, Python with accented words, C++, SQL, odd whitespace, prose): identical.
- Unigram (`potion-multilingual-128M`), 21 samples (German, Russian, Japanese, Arabic, Greek, Hindi, Vietnamese, emoji with ZWJ and skin tones, combining marks, NFKC cases like `ﬁ ① ™ ½`, odd whitespace, literal `[UNK]`): identical. On 3077 lines sampled from mini.nvim, 47 lines differ only in the order of equal-score segmentations of runs like `────` or `8888`; the token multisets, and so the embeddings, are identical. HF runs Viterbi over the whole sentence, m2v per `▁word` with a memo, so float rounding breaks ties differently.

Embeddings against `model2vec.StaticModel.encode` 0.10.0 (cosine between normalized vectors):

| model | samples | min cos | max cos |
|---|---|---|---|
| potion-base-2M | 6 lines | 1.000000 | 1.000000 |
| potion-base-4M | 6 lines | 1.000000 | 1.000000 |
| potion-base-8M | 6 lines | 1.000000 | 1.000000 |
| potion-base-32M | 6 lines | 1.000000 | 1.000000 |
| potion-retrieval-32M | 6 lines | 1.000000 | 1.000000 |
| potion-code-16M-v2 | 6 lines | 0.999952 | 1.000001 (F16 rounding) |
| potion-code-16M | 6 lines | 1.000000 | 1.000000 (0.797329 min before `mapping`/`weights` were applied) |
| potion-multilingual-128M | 19 multilingual samples + 400 mini.nvim lines | 1.000000 | 1.000000 |

### End to end per model

Fresh index each run with the default `workers = 4`. "Ready" = first `search()` call until the index exists. Query times are full `search()` calls (rg + semantic + fusion) on the loaded index; q1 includes loading the model into the editor.

| model | ready | vectors.bin | q1 | q2 | q3 |
|---|---|---|---|---|---|
| potion-base-2M | 0.8 s | 2.7 MB | 34 ms | 37 ms | 20 ms |
| potion-base-4M | 1.5 s | 5.3 MB | 33 ms | 33 ms | 20 ms |
| potion-base-8M | 2.0 s | 10.7 MB | 31 ms | 28 ms | 31 ms |
| potion-base-32M | 1.3 s | 21.3 MB | 41 ms | 30 ms | 24 ms |
| potion-retrieval-32M | 1.5 s | 21.3 MB | 41 ms | 29 ms | 23 ms |
| potion-code-16M-v2 (default) | 1.1 s | 10.7 MB | 38 ms | 28 ms | 31 ms |
| potion-code-16M | 1.1 s | 10.7 MB | 37 ms | 29 ms | 29 ms |
| potion-multilingual-128M | 2.1 s | 10.7 MB | 331 ms | 32 ms | 25 ms |

q1 = "highlight word under cursor", q2 = "parse git diff hunks", q3 = "fuzzy match score". "Ready" varies by ±0.5 s between runs; the differences between the WordPiece models are noise.

Top 3 hits were the same files for every WordPiece model: `lua/mini/cursorword.lua` + `doc/mini-cursorword.txt` for q1, `lua/mini/diff.lua` + `doc/mini-diff.txt` + `readmes/mini-diff.md` for q2, `lua/mini/fuzzy.lua` + `doc/mini-fuzzy.txt` + `tests/test_fuzzy.lua` for q3. potion-multilingual-128M differs on q2 (`tests/test_misc.lua`, `tests/dir-git/help-output`, `tests/test_extra.lua`). On this corpus the rg side of the fusion contributes a lot, so these queries separate models little.

### Against [sgrep](https://github.com/context-dot-dev/sgrep) 0.3.0

Same corpus and queries, top 5, potion-code-16M-v2, both timed from the shell.

| | sgrep | m2v |
|---|---|---|
| full index | 1.0 s (`--refresh-cache`, 12 threads), 571 MB peak RSS | 1.2 s (`workers = 4`), 459 MB summed peak RSS; 3.6 s single process, 233 MB |
| query, cached index | 70-80 ms (CLI start + model load + search) | 20-40 ms inside the editor |

Hits overlapped heavily: both found `cursorword.lua`/`mini-cursorword.txt`, `diff.lua`/`mini-diff.txt`/`mini-diff.md`, `fuzzy.lua`/`mini-fuzzy.txt`/`test_fuzzy.lua`. sgrep ranks `lua/mini/git.lua` first for q2.

### Parallel indexing

Full index, `nvim -l indexer.lua` timed from the shell, summed RSS of the process tree sampled every 50 ms. `workers = 1` is the single-process path. `model.safetensors` is mmap'd read-only, so the processes share the page cache for the model and the summed RSS counts those shared pages once per process.

| model, workers | full index | peak RSS (all processes) |
|---|---|---|
| potion-code-16M-v2, 1 | 3.6 s | 233 MB |
| potion-code-16M-v2, 2 | 2.1 s | 326 MB |
| potion-code-16M-v2, 3 | 1.4 s | 394 MB |
| potion-code-16M-v2, 4 (default on >= 4 cores) | 1.2 s | 459 MB |
| potion-code-16M-v2, 6 | 1.2 s | 490 MB |
| potion-code-16M-v2, 8 | 0.9 s | 651 MB |
| potion-code-16M-v2, 12 | 1.0 s | 783 MB |
| potion-multilingual-128M, 1 | 5.6 s | 812 MB |
| potion-multilingual-128M, 2 | 3.4 s | 1501 MB |
| potion-multilingual-128M, 4 | 2.4 s | 2761 MB |

Incremental rebuilds with `workers = 4`: nothing changed 0.1 s / 78 MB; 1 file changed 0.2 s / 80 MB (embedded in the coordinator); 50 files changed 0.6 s / 277 MB (2 workers).

### Components

| measurement | result |
|---|---|
| model load, mmap + tokenizer.json (potion-code-16M-v2, 32 MB F16) | 12 ms |
| model load (potion-multilingual-128M, 500k-piece Unigram vocab + mmap of 512 MB F32) | 297 ms |
| 500 embeds of a ~400-token chunk | 70 ms (potion-code-16M-v2), 104 ms (potion-base-32M), 135 ms (potion-multilingual-128M) |
| brute-force cosine scan, 10419 × 256 | 5.4 ms |
| tokenizer throughput, mini.nvim line by line (11.3 MB) | WordPiece 2.05 s (5.5 MB/s), Unigram 4.22 s (2.7 MB/s) |
| indexing profile, mini.nvim, single process before optimizations | tokenize 7.1 s, filetype detection 2.7 s, chunking 2.6 s, read 0.5 s, embedding sum 0.6 s |
| full index, nvim config (96 files, 448 chunks) | 1.3 s |
| incremental re-index, nothing changed (96 files) | 0.26 s |

History of the single-process mini.nvim index: 25 s originally; 7.1 s after a per-word WordPiece memo, capping the WordPiece search at the longest vocab entry, one `%p` gsub instead of per-word punctuation matching, and content-based filetype detection only for `#!` files (measured inside the editor); 3.6 s today from the shell. Reading the 512 MB multilingual model into a Lua string instead of mmap cost 1030 MB RSS per process and 1526 MB / 4115 MB peak for a 1- / 4-worker index.
