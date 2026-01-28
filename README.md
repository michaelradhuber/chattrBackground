# SARA - AI Coding Assistant for R

**Version 2.2.0** - Production Ready  
**Updated:** January 28, 2026

SARA is an AI coding assistant for R with direct Ollama integration, tool calling, and optional code execution. It runs as a Shiny app (RStudio addin or console) and can retrieve context, call tools, and execute R code with explicit user confirmation.

## Highlights

- **Direct Ollama integration** via `http://127.0.0.1:11434/api/chat`
- **Tool calling** with proper tool result handling and multi-step loops
- **Code execution (new in v2.2.0)** with explicit confirmation (`do!`, `/run`, `/r <code>`)
- **Context sharing** for script and data via UI buttons or commands
- **Shiny UI** with real-time status and tool call indicators

## Installation

```bash
cd /usr/local/src/chattrBackground
R CMD INSTALL .
```

Or from R:

```r
setwd("/usr/local/src/chattrBackground")
install.packages(".", repos = NULL, type = "source")
```

## Launch

**Option 1: RStudio Addin**  
Addins menu → **"SARA Chat (AI Assistant)"**

**Option 2: R Console**
```r
library(chattrBackground)
sara_chat()
```

## Quick Start Examples

### Execute Code (with confirmation)
```
You: "remove row 30"
You: "do! remove row 30"    # SARA executes with confirmation
You: "/run"                 # Executes SARA's last code suggestion
You: "/r head(iris)"        # Runs arbitrary R code directly
```

### Ask for R Help
```
You: "How do I use tidyr's pivot_wider?"
```
SARA searches documentation and explains usage.

### Share Data Context
```
You: Click "📊 Add Data" or type /data
```
SARA gets your dataframe list and can operate on it.

### Semantic Classification
```
You: "Mark rows as urgent in support_tickets, comment column"
```
SARA uses `run_batch_classify()` and adds an `urgent` column.

### Share Script Context
```
You: Click "📄 Add Script" or type /script
```
SARA receives your active R script for review or refactor guidance.

## Commands Reference

### Code Execution
| Command | Purpose | Example |
|---------|---------|---------|
| `do!` | Execute code (with confirmation) | "do! remove row 30" |
| `/run` | Execute SARA's last suggestion | Type `/run` |
| `/r <code>` | Run arbitrary R code | `/r head(iris)` |
| "▶️ Run Code" button | Execute SARA's last code | UI button |

### Context Sharing
| Command | Purpose | Example |
|---------|---------|---------|
| `/script` | Add current R script | `/script` |
| `/data` | Add dataframes info | `/data` |

## Tools SARA Can Call

1. `search_r_help(topic)` - Search R documentation  
2. `search_r_packages(keyword)` - Search R packages  
3. `fetch_help_page(url, focus, max_chars)` - Fetch online help page  
4. `run_batch_classify(df, column, prompt, ...)` - Semantic text analysis  
5. `execute_r_code(code, description)` - Execute R code with confirmation

## How Tool Calling Works

SARA uses Ollama's native tool calling format and loops until the model returns a final response.

**Execution flow:**
1. Send messages + tool definitions
2. If model returns `tool_calls`, execute each tool
3. Add tool results as `role: "tool"` messages
4. Continue up to 3 iterations

**Key detail:** Empty tool parameters serialize as `{}` (not `[]`) using:
```r
structure(list(), names = character(0))
```

## Architecture Overview

- **UI:** Shiny app with chat history, status messages, and buttons
- **API:** `httr2` calls to `http://127.0.0.1:11434/api/chat`
- **Message format:** System / user / assistant / tool roles
- **Tool loop:** Sequential tool calls with results piped back into chat
- **Code execution:** User-initiated and confirmation-gated

## File Structure

```
chattrBackground/
├── DESCRIPTION
├── NAMESPACE
├── README.md
├── inst/
│   └── rstudio/
│       └── addins.dcf
└── R/
    └── sara_direct.R
```

## Requirements

- **R 4.0+**
- **Ollama** running locally with model named `sara`
- **RStudio** (optional, for addin support)

## Model Setup

SARA expects an Ollama model named `sara` at `http://127.0.0.1:11434`.

```bash
ollama create sara -f Modelfile
# or alias an existing model
ollama cp llama3.2 sara
```

## Troubleshooting

**SARA doesn't respond**
```bash
curl http://127.0.0.1:11434/api/version
ollama list | grep sara
```

**Tool calling fails**
- Check status area for error details
- Share data/script context first (`/data`, `/script`)
- Ensure dataframe/column names are correct

**Batch classify not working**
- Verify `/usr/local/lib/R/site-library/chattr_batch_helper.R` exists
- Ensure target column is text

## Known Limitations

- **Console blocking:** `runApp()` blocks the R console while SARA runs
- **Max 3 tool iterations** to avoid infinite loops
- **Single-user session** per R session
- **Requires Ollama** running locally

## Recent Updates

### v2.2.0 (January 28, 2026)
- Code execution with confirmation (`do!`, `/run`, `/r <code>`, `execute_r_code`)
- "Run Code" button added to UI
- Commands & Tips help card

### v2.1.0 (January 27, 2026)
- Universal language rules moved to Modelfile
- `USE_CUSTOM_INSTRUCTIONS` override mechanism

## License

MIT

## Author

Built for the RStudio/Ollama community
