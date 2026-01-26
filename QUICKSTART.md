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

### 2. Analyze Your Data
```
You: "What dataframes do I have?"
```
SARA calls `get_user_dataframes()` and shows structure + preview.

### 3. Semantic Text Classification
```
You: "Mark rows as urgent in my support_tickets dataframe, comment column"
```
SARA:
1. Retrieves your dataframes
2. Runs `run_batch_classify()` with semantic understanding
3. Adds "urgent" column with appropriate values

### 4. Get Script Context
```
You: "Review my current script for improvements"
```
SARA retrieves your active R script and provides feedback.

### 5. Complex Analysis
```
You: "Find sentiment in customer_reviews dataframe, review_text column"
```
SARA performs semantic sentiment analysis and adds results.

## Pro Tips

✅ **Let SARA retrieve context herself** - Don't paste data, just ask about it

✅ **Be specific about output format** - "Return 1 for urgent, 0 otherwise"

✅ **Watch the status area** - See which tools SARA is calling

✅ **Clear chat to reset** - Use "🗑️ Clear Chat" button for fresh start

## Tool Reference

### Tools SARA Can Call Herself

| Tool | Purpose | Example |
|------|---------|---------|
| `search_r_help()` | R documentation | "How does lm() work?" |
| `search_r_packages()` | Package search | "Find packages for web scraping" |
| `get_user_dataframes()` | Data retrieval | "Show my data" |
| `get_user_script()` | Script retrieval | "Review my code" |
| `run_batch_classify()` | Semantic analysis | "Classify sentiment" |

## Status Messages Explained

| Message | Meaning |
|---------|---------|
| "Processing (iteration 1)..." | Initial API call |
| "🔧 Calling: [tool_name]" | Executing a tool |
| "Generating response..." | Preparing final answer |

## Keyboard Shortcuts

- **Enter** - Send message (when in input field)
- **Shift+Enter** - New line (in future versions)

## Troubleshooting

**Issue:** SARA doesn't respond
- Check Ollama is running: `curl http://127.0.0.1:11434/api/version`
- Verify "sara" model exists: `ollama list | grep sara`

**Issue:** Tool calling fails
- Check error message in status area
- Ensure dataframe names are correct
- Verify RStudio API is available (for script retrieval)

**Issue:** Batch classify not working
- Ensure `/usr/local/lib/R/site-library/chattr_batch_helper.R` exists
- Check dataframe has the specified column
- Verify Ollama model supports long contexts

## Best Practices

### For Data Analysis
```
✅ "Analyze urgency in support_tickets, comment column, add urgent_flag"
❌ "Can you look at my data?"
```

### For Code Help
```
✅ "Show me how to use dplyr filter with multiple conditions"
❌ "dplyr?"
```

### For Semantic Tasks
```
✅ "Classify emails as spam/not spam in email_data, subject column, add category"
❌ "Check if these are spam"
```

## Advanced: Custom Batch Classification

When SARA uses `run_batch_classify()`, she automatically:
1. Retrieves your dataframe structure
2. Constructs a clear task prompt matching your request
3. Processes in configurable batches (default: 10 rows)
4. Adds results as a new column
5. Shows preview of results

You can request specific:
- Output formats ("Return yes/no", "Return 1-5 scale")
- Column names ("add spam_score column")
- Batch sizes ("process 20 at a time")

## Package Info

```r
# Check version
packageVersion("chattrBackground")

# View help
?sara_chat

# Reinstall
R CMD INSTALL /tmp/chattrBackground
```

## Support

Created: January 2026
Version: 2.0.0
Platform: R + Ollama + RStudio
