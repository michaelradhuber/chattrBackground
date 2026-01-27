# SARA Quick Start Guide

## Launch SARA

**Option 1: RStudio Addin**
- Addins menu → "SARA Chat (AI Assistant)"

**Option 2: R Console**
```r
library(chattrBackground)
sara_chat()
```

## Example Use Cases

### 1. Get Help with R Functions
```
You: "How do I use tidyr's pivot_wider?"
```
SARA automatically searches R documentation and explains.

### 2. Share Your Data Context
```
You: Click "Share Data" button or type /data
```
SARA receives your dataframe list and can work with it.

### 3. Semantic Text Classification
```
You: "Mark rows as urgent in my support_tickets dataframe, comment column"
```
SARA:
1. Uses shared data context (or asks you to share it)
2. Runs `run_batch_classify()` with semantic understanding
3. Adds "urgent" column with appropriate values

### 4. Share Script Context
```
You: Click "Share Script" button or type /script, then ask for review
```
SARA receives your active R script and provides feedback.

### 5. Semantic Analysis
```
1. Click "Share Data" button first
2. You: "Find sentiment in customer_reviews dataframe, review_text column"
```
SARA uses `run_batch_classify()` to perform semantic analysis and adds results.

## Pro Tips

✅ **Share context first** - Use "Share Script" or "Share Data" buttons before asking questions

✅ **Be specific about output format** - "Return 1 for urgent, 0 otherwise"

✅ **Watch the status area** - See which tools SARA is calling

✅ **Clear chat to reset** - Use "🗑️ Clear Chat" button for fresh start

## Tool Reference

### Tools SARA Can Call

| Tool | Purpose | Example |
|------|---------|---------|
| `search_r_help()` | R documentation search | "How does lm() work?" |
| `search_r_packages()` | Package search | "Find packages for web scraping" |
| `fetch_help_page()` | Fetch online help page | Called after search_r_help |
| `run_batch_classify()` | Semantic text analysis | "Classify sentiment" |

### Context Sharing (Not Tools)

| Method | Purpose | How to Use |
|--------|---------|------------|
| Share Script | Inject R script into chat | Click "Share Script" or type `/script` |
| Share Data | Inject dataframe list | Click "Share Data" or type `/data` |

## Status Messages Explained

| Message | Meaning |
|---------|---------|
| "Processing (iteration 1)..." | Initial API call |
| "🔧 Calling: [tool_name]" | Executing a tool |
| "Generating response..." | Preparing final answer |

## UI Features

- **Enter** - Send message
- **Share Script** - Inject current R script into next message
- **Share Data** - Inject dataframe list into next message
- **Clear Chat** - Reset conversation history
- **Debug Mode** - Toggle debug output (for development)

## Troubleshooting

**SARA doesn't respond**
```bash
# Check Ollama is running
curl http://127.0.0.1:11434/api/version

# Verify sara model exists
ollama list | grep sara
```

**Tool calling fails**
- Check error message in status area
- Verify dataframe names are correct (share data first)
- Ensure RStudioAPI is available for script sharing

**Batch classify not working**
- Verify `/usr/local/lib/R/site-library/chattr_batch_helper.R` exists
- Share data context first (Share Data button or `/data`)
- Check dataframe has the specified column
- Ensure column contains text data

## Best Practices

### For Data Analysis
```
✅ Share data first, then: "Analyze urgency in support_tickets, comment column, add urgent_flag"
❌ "Can you look at my data?" (without sharing context)
```

### For Code Help
```
✅ "Show me how to use dplyr filter with multiple conditions"
✅ Share script first, then: "Review my dplyr code"
```

### For Semantic Tasks
```
✅ Share data, then: "Classify emails as spam/not spam in email_data, subject column, add category"
❌ "Check if these are spam" (too vague, no context)

## Advanced: Batch Classification

When SARA uses `run_batch_classify()`:
1. Uses shared dataframe context (make sure to share data first)
2. Constructs a clear task prompt matching your request
3. Processes in configurable batches (default: 10 rows)
4. Adds results as a new column to your dataframe
5. Shows preview of results

You can request specific:
- Output formats: "Return yes/no" or "Return 1-5 scale"
- Column names: "add spam_score column"
- Batch sizes: "process 20 at a time"

## Package Info

```r
# Check version
packageVersion("chattrBackground")

# View help
?sara_chat

# Reinstall (from source directory)
# cd /usr/local/src/chattrBackground
# R CMD INSTALL .
```

## Known Limitations

⚠️ **Console Blocking** - SARA blocks the R console while running
- You cannot execute R commands while SARA UI is active
- Close SARA to regain console access
- Future enhancement: Non-blocking mode (see IMPLEMENTATION.md)

## Recent Updates (January 27, 2026)

- Universal language rules in Modelfile (prevents Thai/Chinese output)
- `USE_CUSTOM_INSTRUCTIONS` override mechanism
- Clarified tool vs. context sharing distinction
- Improved documentation accuracy

## Info

**Version:** 2.0.0
**Updated:** January 27, 2026
**Platform:** R + Ollama + RStudio
**Source:** `/usr/local/src/chattrBackground`

For detailed technical information, see `IMPLEMENTATION.md`
