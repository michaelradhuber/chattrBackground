# SARA - AI Coding Assistant

**Version 2.0.0** - Production Ready

## What is SARA?

SARA is an AI coding assistant for R with direct Ollama integration and autonomous tool calling support. Unlike traditional chat interfaces, SARA can **proactively retrieve context** and **perform analysis** without you having to manually provide data.

## Key Features

### 🔧 5 Built-in Tools (SARA calls these herself)

1. **search_r_help(topic)** - Search R official documentation
2. **search_r_packages(keyword)** - Search R packages/extensions  
3. **get_user_dataframes()** - Auto-retrieve all dataframes with structure & preview
4. **get_user_script()** - Auto-retrieve your active R script
5. **run_batch_classify()** - Semantic text analysis on dataframe columns

### ✨ What Makes SARA Special

- **No manual context sharing needed** - SARA retrieves data/scripts herself when needed
- **Semantic analysis built-in** - Classify, score, or categorize text by meaning (not keywords)
- **Real-time status updates** - See exactly which tools SARA is calling
- **Direct Ollama integration** - No background processes, runs in Shiny
- **Tool execution loop** - Proper multi-step reasoning with tool results

## Installation

```r
# Install from source
R CMD INSTALL /tmp/chattrBackground

# Or in R
setwd("/tmp/chattrBackground")
install.packages(".", repos = NULL, type = "source")
```

## Usage

### RStudio Addin

After installation, you'll see a new addin in RStudio:

**"SARA Chat (AI Assistant)"**

Click it to launch SARA in the Viewer pane.

### From R Console

```r
library(chattrBackground)
sara_chat()
```

## Example Interactions

### Automatic Data Retrieval

**You:** "Analyze my dataframes"

**SARA:** 
- 🔧 Calls: `get_user_dataframes()`
- Shows structure and preview of all your data
- Suggests analysis approaches

### Semantic Analysis

**You:** "Mark urgent support tickets in my tickets dataframe"

**SARA:**
1. 🔧 Calls: `get_user_dataframes()` - checks your data
2. 🔧 Calls: `run_batch_classify()` with proper task prompt
3. Adds an "urgent" column with 1/0 values based on semantic understanding

### R Help Search

**You:** "How do I use dplyr's group_by?"

**SARA:**
- 🔧 Calls: `search_r_help("group_by")`
- Provides relevant documentation and examples

## Technical Details

### Architecture

- **Framework:** Shiny UI with reactive messaging
- **API:** Direct HTTP calls to Ollama `/api/chat` endpoint
- **Tool Format:** Ollama function calling JSON schema
- **Message History:** Proper assistant/user/tool message sequencing
- **Dependencies:** shiny, httr2, rstudioapi (optional)

### Tool Calling Implementation

SARA uses Ollama's native tool calling format with proper JSON serialization:

```r
# Empty parameters serialize as {} not []
properties = structure(list(), names = character(0))
```

The tool execution loop:
1. Send messages with tool definitions
2. If model returns `tool_calls`, execute each tool
3. Add tool results as `role: "tool"` messages
4. Continue until model returns final response

### Key Technical Achievement

Fixed the critical issue where empty tool parameters were serializing as `[]` instead of `{}`, causing Ollama to reject tool calls. Solution: use `structure(list(), names = character(0))`.

## File Structure

```
/tmp/chattrBackground/
├── DESCRIPTION          # Package metadata
├── NAMESPACE           # Exports sara_chat
├── README.md           # This file
├── inst/
│   └── rstudio/
│       └── addins.dcf  # RStudio addin configuration
└── R/
    └── sara_direct.R   # Main SARA implementation (612 lines)
```

## Status Messages

SARA shows real-time status in the UI:

- "Processing (iteration 1)..." - Initial API call
- "🔧 Calling: search_r_help" - Executing tool
- "Generating response..." - Preparing final answer
- Errors displayed inline

## Comparison with Previous Version

| Feature | v1.0 (chattr) | v2.0 (SARA) |
|---------|---------------|-------------|
| Backend | Background R job | Direct Shiny |
| Port management | User-specific ports | Not needed |
| Context sharing | Manual addins | Automatic tools |
| Tool calling | None | 5 built-in tools |
| Semantic analysis | None | Built-in |
| Dependencies | chattr package | shiny, httr2 only |
| Status visibility | Console output | UI status area |

## Requirements

- **R 4.0+**
- **Ollama** running locally with "sara" model
- **RStudio** (optional, for addin support)

## Model Configuration

SARA expects an Ollama model named "sara" at `http://127.0.0.1:11434`.

To set up:
```bash
# If you have a custom model
ollama create sara -f Modelfile

# Or use an existing model with alias
ollama cp llama3.2 sara
```

## Future Enhancements

Potential additions:
- [ ] Plot generation tool
- [ ] Package installation tool
- [ ] Code execution sandbox
- [ ] Git integration tools
- [ ] Database query tools

## License

MIT

## Author

Built for the RStudio/Ollama community
Version 2.0.0 - January 2026
