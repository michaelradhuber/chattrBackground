#' SARA Chat Interface
#'
#' Direct Ollama API integration with tool calling support for SARA
#' @param as_background Run as background job (default: TRUE in RStudio)
#' @export
sara_chat <- function(as_background = NULL) {

  # Auto-detect: run as background by default in RStudio
  if (is.null(as_background)) {
    as_background <- requireNamespace("rstudioapi", quietly = TRUE) && 
                     rstudioapi::isAvailable()
  }

  # Null coalescing operator
  `%||%` <- function(a, b) if (is.null(a)) b else a

  # Get user-specific port (for consistency, though not used in direct API)
  get_user_port <- function() {
    user <- Sys.info()["user"]
    hash_val <- sum(as.integer(charToRaw(user))) %% 100
    port <- 7700 + hash_val
    return(port)
  }

  # ============================================================================
  # HELPER FUNCTIONS (Tools that SARA can call)
  # ============================================================================

  # 1. Search R official manual
  search_r_help <- function(topic) {
    tryCatch({
      results <- capture.output(help.search(topic, agrep = FALSE))
      if (length(results) == 0) {
        return(paste("No help found for:", topic))
      }
      return(paste(head(results, 20), collapse = "\n"))
    }, error = function(e) {
      return(paste("Error searching help:", e$message))
    })
  }

  # 2. Search R extensions/packages
  search_r_packages <- function(keyword) {
    tryCatch({
      results <- capture.output(help.search(keyword, agrep = FALSE, package = NULL))
      if (length(results) == 0) {
        return(paste("No packages found for:", keyword))
      }
      return(paste(head(results, 20), collapse = "\n"))
    }, error = function(e) {
      return(paste("Error searching packages:", e$message))
    })
  }

  # 3. Get all dataframes from user environment
  get_user_dataframes <- function() {
    env_objects <- ls(envir = .GlobalEnv)
    dataframes <- env_objects[sapply(env_objects, function(x) {
      is.data.frame(get(x, envir = .GlobalEnv))
    })]

    if (length(dataframes) == 0) {
      return("No dataframes found in user environment.")
    }

    context_parts <- list()
    context_parts[[1]] <- "Here are the dataframes in the user's R environment:\n"

    for (df_name in dataframes) {
      df <- get(df_name, envir = .GlobalEnv)
      str_output <- capture.output(str(df, max.level = 1))
      preview <- capture.output(print(head(df, 3)))

      context_parts[[length(context_parts) + 1]] <- sprintf(
        "\n## %s\n\nStructure:\n%s\n\nPreview:\n%s\n",
        df_name,
        paste(str_output, collapse = "\n"),
        paste(preview, collapse = "\n")
      )
    }

    return(paste(context_parts, collapse = "\n"))
  }

  # 4. Get active R script
  get_user_script <- function() {
    if (!requireNamespace("rstudioapi", quietly = TRUE)) {
      return("rstudioapi package required")
    }

    if (!rstudioapi::isAvailable()) {
      return("RStudio not available")
    }

    tryCatch({
      context <- rstudioapi::getActiveDocumentContext()

      if (is.null(context) || is.null(context$contents) || length(context$contents) == 0) {
        return("No active R script found")
      }

      script_content <- paste(context$contents, collapse = "\n")
      script_path <- context$path
      script_name <- ifelse(nzchar(script_path), basename(script_path), "Untitled")

      return(sprintf(
        "User's current R script (%s):\n\n```r\n%s\n```\n",
        script_name,
        script_content
      ))

    }, error = function(e) {
      return(paste("Error:", e$message))
    })
  }

  # 5. Run batch classification (semantic analysis on dataframe)
  run_batch_classify <- function(df_name, column_name, task_prompt, result_column = "result", batch_size = 10) {
    tryCatch({
      # Source the helper functions
      source("/usr/local/lib/R/site-library/chattr_batch_helper.R")

      # Get the dataframe from global environment
      if (!exists(df_name, envir = .GlobalEnv)) {
        return(paste("Error: Dataframe", df_name, "not found in environment"))
      }

      df <- get(df_name, envir = .GlobalEnv)

      # Run batch classify
      result_df <- chattr_batch_classify(
        df = df,
        column_name = column_name,
        task_prompt = task_prompt,
        result_column = result_column,
        batch_size = batch_size
      )

      # Save result back to global environment
      assign(df_name, result_df, envir = .GlobalEnv)

      # Return success message with preview
      preview <- capture.output(print(head(result_df, 5)))
      return(paste0(
        "Success! Added column '", result_column, "' to dataframe '", df_name, "'.\n\n",
        "Preview of first 5 rows:\n",
        paste(preview, collapse = "\n")
      ))

    }, error = function(e) {
      return(paste("Error running batch classify:", e$message))
    })
  }

  # ============================================================================
  # TOOL DEFINITIONS for Ollama
  # ============================================================================

  get_tools <- function() {
    list(
      list(
        type = "function",
        `function` = list(
          name = "search_r_help",
          description = "Search R official documentation and help files for a specific topic or function",
          parameters = list(
            type = "object",
            properties = list(
              topic = list(
                type = "string",
                description = "The topic or function name to search for in R help"
              )
            ),
            required = list("topic")
          )
        )
      ),
      list(
        type = "function",
        `function` = list(
          name = "search_r_packages",
          description = "Search for R packages and extensions by keyword",
          parameters = list(
            type = "object",
            properties = list(
              keyword = list(
                type = "string",
                description = "Keyword to search for in R packages"
              )
            ),
            required = list("keyword")
          )
        )
      ),
      list(
        type = "function",
        `function` = list(
          name = "get_user_dataframes",
          description = "Retrieve all dataframes from the user's R environment with structure and preview",
          parameters = list(
            type = "object",
            properties = structure(list(), names = character(0))  # Empty named list = {}
          )
        )
      ),
      list(
        type = "function",
        `function` = list(
          name = "get_user_script",
          description = "Retrieve the user's currently active R script from the editor",
          parameters = list(
            type = "object",
            properties = structure(list(), names = character(0))  # Empty named list = {}
          )
        )
      ),
      list(
        type = "function",
        `function` = list(
          name = "run_batch_classify",
          description = "Perform semantic analysis on a dataframe column and add results as a new column. Use this for classification, sentiment analysis, urgency detection, or any task requiring understanding of text meaning (not just keywords).",
          parameters = list(
            type = "object",
            properties = list(
              df_name = list(
                type = "string",
                description = "Name of the dataframe to analyze"
              ),
              column_name = list(
                type = "string",
                description = "Name of the column containing text to analyze"
              ),
              task_prompt = list(
                type = "string",
                description = "Description of the analysis task, e.g. 'Determine if this comment is urgent and needs immediate attention'"
              ),
              result_column = list(
                type = "string",
                description = "Name for the new column to store results (default: 'result')"
              ),
              batch_size = list(
                type = "integer",
                description = "Number of rows to process per batch (default: 10)"
              )
            ),
            required = list("df_name", "column_name", "task_prompt")
          )
        )
      )
    )
  }

  # Execute tool by name
  execute_tool <- function(tool_name, tool_args) {
    result <- switch(tool_name,
      "search_r_help" = search_r_help(tool_args$topic),
      "search_r_packages" = search_r_packages(tool_args$keyword),
      "get_user_dataframes" = get_user_dataframes(),
      "get_user_script" = get_user_script(),
      "run_batch_classify" = run_batch_classify(
        df_name = tool_args$df_name,
        column_name = tool_args$column_name,
        task_prompt = tool_args$task_prompt,
        result_column = tool_args$result_column %||% "result",
        batch_size = tool_args$batch_size %||% 10
      ),
      paste("Unknown tool:", tool_name)
    )
    return(result)
  }

  # ============================================================================
  # SARA SYSTEM PROMPT
  # ============================================================================

  get_system_prompt <- function() {
    "USE_CUSTOM_INSTRUCTIONS

Use the 'Tidy Modeling with R' (https://www.tmwr.org/) book as main reference
Use the 'R for Data Science' (https://r4ds.had.co.nz/) book as main reference
Use tidyverse packages: readr, ggplot2, dplyr, tidyr
For models, use tidymodels packages: recipes, parsnip, yardstick, workflows, broom
Avoid explanations unless requested by user, expecting code only

You are a helpful coding assistant that uses R and the tidyverse

AVAILABLE TOOLS:
You have access to these helper functions you can call yourself:

1. search_r_help(topic) - Search R official documentation
2. search_r_packages(keyword) - Search R packages/extensions
3. get_user_dataframes() - Retrieve all dataframes from user's environment
4. get_user_script() - Get the user's currently open R script
5. run_batch_classify() - Perform semantic text analysis on dataframe columns

When a user asks about data or scripts you don't have context for, use get_user_dataframes() or get_user_script() to retrieve it yourself.
When you're unsure about R functions or packages, use search_r_help() or search_r_packages().

SEMANTIC ANALYSIS: When users ask you to semantically analyze text in dataframes (classify, score, categorize based on meaning, not keywords), use run_batch_classify():

1. First call get_user_dataframes() to see the data structure
2. Then call run_batch_classify() providing:
   - df_name: the dataframe name
   - column_name: the text column to analyze
   - task_prompt: Clear instruction that specifies BOTH the analysis task AND the expected output format based on user's request
   - result_column: appropriate column name based on user's request

CRITICAL: Your task_prompt must explicitly specify what values to return. If user says 'set to 1 if urgent', use 'Return 1 if urgent, otherwise 0'. If user says 'categorize', specify the categories. Match the user's intent for output format.

IMPORTANT: For semantic text analysis, ALWAYS use run_batch_classify() tool. Do NOT suggest keyword-based regex or grepl solutions."
  }

  # ============================================================================
  # OLLAMA API CALL WITH TOOL SUPPORT (with status callback)
  # ============================================================================

  call_ollama_with_tools <- function(messages, tools = NULL, max_iterations = 3, status_callback = NULL, debug = FALSE, debug_callback = NULL) {
    iteration <- 0

    while (iteration < max_iterations) {
      iteration <- iteration + 1

      if (!is.null(status_callback)) {
        status_callback(paste("Processing (iteration", iteration, ")..."))
      }

      tryCatch({
        body <- list(
          model = "sara",
          messages = messages,
          stream = FALSE
        )

        # Add tools if provided
        if (!is.null(tools) && length(tools) > 0) {
          body$tools <- tools
        }

        response <- httr2::request("http://127.0.0.1:11434/api/chat") |>
          httr2::req_body_json(body, auto_unbox = TRUE) |>
          httr2::req_perform() |>
          httr2::resp_body_json()

        message_content <- response$message

        # Check if model wants to call a tool
        if (!is.null(message_content$tool_calls) && length(message_content$tool_calls) > 0) {

          # Add assistant's tool call message to history
          messages[[length(messages) + 1]] <- list(
            role = "assistant",
            content = "",
            tool_calls = message_content$tool_calls
          )

          # Execute each tool call
          for (i in seq_along(message_content$tool_calls)) {
            tool_call <- message_content$tool_calls[[i]]
            tool_name <- tool_call$`function`$name
            if (debug && !is.null(debug_callback)) {
              debug_callback(sprintf("🔧 Calling tool: %s", tool_name))
            }
            tool_args <- tool_call$`function`$arguments

            if (!is.null(status_callback)) {
              status_callback(paste0("🔧 Calling: ", tool_name))
            }

            # Execute the tool
            tool_result <- execute_tool(tool_name, tool_args)
            if (debug && !is.null(debug_callback)) {
              debug_callback(sprintf("✅ Tool %s completed", tool_name))
            }

            # Add tool result to messages
            messages[[length(messages) + 1]] <- list(
              role = "tool",
              content = tool_result
            )
          }

          # Continue loop to get final response
          next

        } else {
          # No tool calls, return final response
          if (!is.null(status_callback)) {
            status_callback("Generating response...")
          }

          return(list(
            content = message_content$content %||% "",
            messages = messages
          ))
        }

      }, error = function(e) {
        if (!is.null(status_callback)) {
          status_callback(paste("Error:", e$message))
        }
        return(list(
          content = paste("Error calling Ollama:", e$message),
          messages = messages
        ))
      })
    }

    # Max iterations reached
    return(list(
      content = "Maximum tool calling iterations reached.",
      messages = messages
    ))
  }

  # ============================================================================
  # SHINY UI
  # ============================================================================

  ui <- shiny::fluidPage(
    shiny::titlePanel("SARA Chat"),
    shinyjs::useShinyjs(),
    shiny::tags$head(
      shiny::tags$style(shiny::HTML("
        #sara_spinner {
          display: none;
          width: 16px;
          height: 16px;
          border: 2px solid #ccc;
          border-top-color: #28a745;
          border-radius: 50%;
          animation: sara_spin 0.8s linear infinite;
          margin-right: 6px;
        }
        @keyframes sara_spin {
          to { transform: rotate(360deg); }
        }
      ")
    )),

    shiny::fluidRow(
      shiny::column(12,
        shiny::p(style = "color: #666;",
          paste0("User: ", Sys.info()["user"]),
          shiny::br(),
          shiny::tags$span(style = "color: #28a745;", "✓ Tool Calling Enabled")
        )
      )
    ),

    shiny::fluidRow(
      shiny::column(12,
        shiny::actionButton("clear_chat", "🗑️ Clear Chat", class = "btn-warning"),
        shiny::actionButton("close_app", "✖️ Close SARA", class = "btn-danger", style = "margin-left: 10px;"),
        shiny::actionButton("toggle_debug", "🐛 Debug", class = "btn-info", style = "margin-left: 10px;"),
        shiny::hr()
      )
    ),

    shiny::fluidRow(
      shiny::column(12,
        shiny::div(
          id = "chat_container",
          style = "height: 400px; overflow-y: scroll; border: 1px solid #ddd; padding: 10px; background: #f9f9f9;",
          shiny::uiOutput("chat_history")
        ),
        shiny::div(
          id = "debug_output",
          style = "margin-top: 10px; padding: 10px; background-color: #f8f9fa; border: 1px solid #dee2e6; border-radius: 4px; font-family: monospace; font-size: 12px; max-height: 200px; overflow-y: auto; display: none;",
          shiny::uiOutput("debug_messages")
        )
      )
    ),

    shiny::fluidRow(
      shiny::column(12,
        shiny::div(
          id = "status_area",
          style = "min-height: 20px; padding: 5px; color: #666; font-size: 0.9em; display: flex; align-items: center;",
          shiny::div(id = "sara_spinner"),
          shiny::uiOutput("status_message")
        )
      )
    ),

    shiny::fluidRow(
      shiny::column(10,
        shiny::textInput("user_input", NULL,
                        placeholder = "Ask SARA anything... She can search R help and retrieve your data automatically!",
                        width = "100%")
      ),
      shiny::column(2,
        shiny::actionButton("send", "Send", class = "btn-success", width = "100%")
      )
    ),

    shiny::tags$script(shiny::HTML("
      $(document).on('keydown', '#user_input', function(e) {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          $('#send').click();
        }
      });

      function scrollToBottom() {
        var container = document.getElementById('chat_container');
        if (container) {
          container.scrollTop = container.scrollHeight;
        }
      }

      var observer = new MutationObserver(scrollToBottom);
      var container = document.getElementById('chat_container');
      if (container) {
        observer.observe(container, {
          childList: true,
          subtree: true
        });
      }
    "))
  )

  # ============================================================================
  # SHINY SERVER
  # ============================================================================

  server <- function(input, output, session) {

    # Initialize chat history with system message
    chat_history <- shiny::reactiveVal(list(
      list(role = "system", content = get_system_prompt())
    ))
    
    # Debug mode toggle
    debug_enabled <- shiny::reactiveVal(FALSE)
    debug_log <- shiny::reactiveVal(character(0))

    append_debug <- function(msg) {
      if (!isTRUE(debug_enabled())) return()
      current_debug <- debug_log()
      timestamp <- format(Sys.time(), "%H:%M:%S")
      current_debug[[length(current_debug) + 1]] <- paste0("[", timestamp, "] ", msg)
      debug_log(current_debug)
    }

    contains_forbidden_language <- function(text) {
      if (is.null(text) || !nzchar(text)) return(FALSE)
      grepl("[\\p{Han}\\p{Thai}]", text, perl = TRUE)
    }

    detect_target_language <- function(text) {
      if (is.null(text) || !nzchar(text)) return("English")
      if (grepl("[äöüÄÖÜß]", text)) return("German")
      "English"
    }

    # Status message for showing what SARA is doing
    status_msg <- shiny::reactiveVal("")

    # Render status message
    output$status_message <- shiny::renderUI({
      msg <- status_msg()
      if (nchar(msg) > 0) {
        shiny::tags$span(style = "color: #007bff;", msg)
      } else {
        shiny::tags$span("")
      }
    })

    output$debug_messages <- shiny::renderUI({
      messages <- debug_log()
      if (length(messages) > 0) {
        shiny::HTML(paste(messages, collapse = '<br>'))
      } else {
        shiny::tags$span("")
      }
    })

    # Render chat history
    output$chat_history <- shiny::renderUI({
      messages <- chat_history()

      if (length(messages) <= 1) {
        return(shiny::p(style = "color: #999;",
                       "Start chatting with SARA... She can search R help, retrieve data/scripts, and perform semantic analysis automatically!"))
      }

      # Skip system message and tool messages in display
      display_messages <- messages[-1]
      display_messages <- Filter(function(msg) msg$role != "tool", display_messages)

      ui_messages <- lapply(display_messages, function(msg) {
        if (msg$role == "user") {
          shiny::div(
            style = "margin: 10px 0; padding: 10px; background: #e3f2fd; border-radius: 5px;",
            shiny::tags$strong("You:"),
            shiny::tags$pre(style = "margin: 5px 0; white-space: pre-wrap;", msg$content)
          )
        } else if (msg$role == "assistant") {
          # Show tool calls if present
          tool_info <- NULL
          if (!is.null(msg$tool_calls)) {
            tool_names <- sapply(msg$tool_calls, function(tc) tc$`function`$name)
            tool_info <- shiny::tags$div(
              style = "color: #28a745; font-size: 0.9em; margin: 5px 0;",
              paste("🔧 Called:", paste(tool_names, collapse = ", "))
            )
          }

          shiny::div(
            style = "margin: 10px 0; padding: 10px; background: #fff; border: 1px solid #ddd; border-radius: 5px;",
            shiny::tags$strong("SARA:"),
            tool_info,
            shiny::tags$pre(style = "margin: 5px 0; white-space: pre-wrap;", msg$content)
          )
        }
      })

      shiny::tagList(ui_messages)
    })

    # Send message
    shiny::observeEvent(input$send, {
      shiny::req(input$user_input)
      user_msg <- input$user_input

      if (nchar(trimws(user_msg)) == 0) return()

      # Add user message
      current_history <- chat_history()
      current_history[[length(current_history) + 1]] <- list(
        role = "user",
        content = user_msg
      )
      chat_history(current_history)

      shiny::updateTextInput(session, "user_input", value = "")
      shinyjs::disable("user_input")
      shinyjs::disable("send")
      shinyjs::show("sara_spinner")

      if (isTRUE(debug_enabled())) {
        append_debug(paste0("📩 Message received: ", substr(user_msg, 1, 50), if (nchar(user_msg) > 50) "..." else ""))
        append_debug("▶️ Starting SARA processing...")
      }

      status_msg("SARA is thinking...")

      # Call Ollama with tool support and status callback
      result <- call_ollama_with_tools(
        current_history,
        get_tools(),
        status_callback = function(msg) {
          status_msg(msg)
        },
        debug = debug_enabled(),
        debug_callback = append_debug
      )

      if (contains_forbidden_language(result$content)) {
        target_lang <- detect_target_language(user_msg)
        append_debug(paste0("⚠️ Non-English output detected; retrying in ", target_lang, "..."))
        retry_messages <- current_history
        retry_messages[[1]]$content <- paste0(
          retry_messages[[1]]$content,
          "\n\nLANGUAGE OVERRIDE: Respond only in ", target_lang, ". The user's last message is in ", target_lang, "."
        )
        result <- call_ollama_with_tools(
          retry_messages,
          get_tools(),
          status_callback = function(msg) {
            status_msg(msg)
          },
          debug = debug_enabled(),
          debug_callback = append_debug
        )
      }

      if (isTRUE(debug_enabled())) {
        append_debug("✅ SARA processing complete")
      }

      # Update history with new messages (including tool calls)
      chat_history(result$messages)

      # Add final response
      if (!is.null(result$content) && nchar(result$content) > 0) {
        current_history <- chat_history()
        current_history[[length(current_history) + 1]] <- list(
          role = "assistant",
          content = result$content
        )
        chat_history(current_history)
      }

      status_msg("")
      shinyjs::hide("sara_spinner")
      shinyjs::enable("user_input")
      shinyjs::enable("send")
    })

    # Clear chat
    shiny::observeEvent(input$clear_chat, {
      chat_history(list(
        list(role = "system", content = get_system_prompt())
      ))
      status_msg("")
      shiny::showNotification("Chat cleared!", type = "message", duration = 2)
    })
    
    # Close app
    shiny::observeEvent(input$close_app, {
      shiny::showNotification("Closing SARA...", type = "message", duration = 1)
      shiny::stopApp()
    })

    # Toggle debug
    shiny::observeEvent(input$toggle_debug, {
      if (isTRUE(debug_enabled())) {
        debug_enabled(FALSE)
        shiny::updateActionButton(session, 'toggle_debug', label = '🐛 Debug')
        shinyjs::removeClass('toggle_debug', 'btn-success')
        shinyjs::addClass('toggle_debug', 'btn-info')
        shinyjs::hide('debug_output')
        debug_log(character(0))
      } else {
        debug_enabled(TRUE)
        debug_log(character(0))
        shiny::updateActionButton(session, 'toggle_debug', label = '🐛 Debug ON')
        shinyjs::removeClass('toggle_debug', 'btn-info')
        shinyjs::addClass('toggle_debug', 'btn-success')
        shinyjs::show('debug_output')
        append_debug('Debug enabled')
      }
    })
  }

  # Run app in RStudio Viewer as a background job
  
  if (as_background && requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    # Create a temporary script to run as a background job
    temp_script <- tempfile(fileext = ".R")
    
    # Find a port to use
    port <- as.integer(runif(1, 8000, 9000))
    
    # Write a complete standalone script  
    writeLines(c(
      "library(shiny)",
      "library(httr2)",
      "library(chattrBackground)",
      "",
      sprintf("port <- %d", port),
      "",
      "# Disable auto browser launch",
      "options(shiny.launch.browser = FALSE)",
      "",
      "# Get the app",
      "app <- sara_chat(as_background = FALSE)",
      "",
      "# Start server in background",
      "shiny::runApp(app, port = port, host = '127.0.0.1', launch.browser = FALSE)"
    ), temp_script)
    
    # Launch as background job
    rstudioapi::jobRunScript(
      path = temp_script,
      name = "SARA Chat",
      importEnv = TRUE
    )
    
    # Give server a moment to start, then open viewer
    Sys.sleep(1.5)
    url <- sprintf("http://127.0.0.1:%d", port)
    rstudioapi::viewer(url)
    
    message("✓ SARA Chat started as background job")
    message(sprintf("  - Port: %d", port))
    message("  - Your console is free to use")
    message("  - Stop via Background Jobs pane")
    
    return(invisible(NULL))
  }
  
  # Run directly (either as_background = FALSE or not in RStudio)
  app <- shiny::shinyApp(ui = ui, server = server)
  
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    options(shiny.launch.browser = rstudioapi::viewer)
  }
  
  return(app)
}
