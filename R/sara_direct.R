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
    "LANGUAGE RULES - READ FIRST:
- NEVER respond in Thai (ไทย) - this is FORBIDDEN
- NEVER respond in Chinese (中文) - this is FORBIDDEN
- ONLY use English or German
- Default to English unless user writes in German
- If user writes in English → respond in English
- If user writes in German → respond in German

You are a helpful R coding assistant using tidyverse and tidymodels.

AVAILABLE TOOLS (call these yourself when needed):
1. search_r_help(topic) - Search R documentation
2. search_r_packages(keyword) - Search R packages
3. get_user_dataframes() - Get all dataframes from user environment
4. get_user_script() - Get user's active R script
5. run_batch_classify(df_name, column_name, task_prompt, result_column, batch_size) - Semantic text analysis

When user asks about their data/scripts, call get_user_dataframes() or get_user_script() automatically.
For semantic analysis (classification, sentiment, urgency), use run_batch_classify() - NOT regex.

References: tmwr.org, r4ds.had.co.nz
Packages: dplyr, ggplot2, tidyr, recipes, parsnip, workflows
Be concise - provide code unless user asks for explanations."
  }

  # ============================================================================
  # OLLAMA API CALL WITH TOOL SUPPORT (with status callback)
  # ============================================================================

  call_ollama_with_tools <- function(messages, tools = NULL, max_iterations = 3, status_callback = NULL) {
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
            content = message_content$content %||% "",
            tool_calls = message_content$tool_calls
          )

          # Execute each tool call
          for (i in seq_along(message_content$tool_calls)) {
            tool_call <- message_content$tool_calls[[i]]
            tool_name <- tool_call$`function`$name
            tool_args <- tool_call$`function`$arguments

            if (!is.null(status_callback)) {
              status_callback(paste0("🔧 Calling: ", tool_name))
            }

            # Execute the tool
            tool_result <- execute_tool(tool_name, tool_args)

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
    shinyjs::useShinyjs(),
    shiny::titlePanel("SARA Chat"),

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
        )
      )
    ),

    shiny::fluidRow(
      shiny::column(12,
        shiny::div(
          id = "status_area",
          style = "min-height: 20px; padding: 5px; color: #666; font-size: 0.9em;",
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
      $(document).on('keypress', function(e) {
        if(e.which == 13 && !e.shiftKey) {
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
    # Initialize chat history with system message
    chat_history <- shiny::reactiveVal(list(
      list(role = "system", content = get_system_prompt())
    ))
    
    # Debug mode toggle
    debug_enabled <- shiny::reactiveVal(FALSE)
      list(role = "system", content = get_system_prompt())
    ))

    # Status message for showing what SARA is doing
    status_msg <- shiny::reactiveVal("")

    # Create ExtendedTask for async API calls
    sara_task <- shiny::ExtendedTask$new(function(messages, tools, debug = FALSE) {
      # This runs in a separate R process
      library(httr2)
      
      # Define execute_tool inside the task
      execute_tool <- function(tool_name, tool_args) {
        # Tool implementations need to be here or passed in
        result <- switch(tool_name,
          "search_r_help" = {
            tryCatch({
              results <- capture.output(help.search(tool_args$topic, agrep = FALSE))
              if (length(results) == 0) paste("No help found for:", tool_args$topic)
              else paste(head(results, 20), collapse = "\n")
            }, error = function(e) paste("Error:", e$message))
          },
          "search_r_packages" = {
            tryCatch({
              results <- capture.output(help.search(tool_args$keyword, agrep = FALSE, package = NULL))
              if (length(results) == 0) paste("No packages found for:", tool_args$keyword)
              else paste(head(results, 20), collapse = "\n")
            }, error = function(e) paste("Error:", e$message))
          },
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
      
      # Run the API call with tool loop
      iteration <- 0
      max_iterations <- 3
      
      while (iteration < max_iterations) {
        iteration <- iteration + 1
        if (debug) cat(sprintf("[SARA Debug] Iteration %d/%d\n", iteration, max_iterations))
        
        body <- list(
          model = "sara",
          messages = messages,
          stream = FALSE
        )
        
        if (!is.null(tools) && length(tools) > 0) {
          body$tools <- tools
        }
        
        response <- httr2::request("http://127.0.0.1:11434/api/chat") |>
          httr2::req_body_json(body, auto_unbox = TRUE) |>
          httr2::req_perform() |>
          httr2::resp_body_json()
        
        message_content <- response$message
        
        # Check for tool calls
        if (!is.null(message_content$tool_calls) && length(message_content$tool_calls) > 0) {
          # Add assistant message
          messages[[length(messages) + 1]] <- list(
            role = "assistant",
            content = message_content$content %||% "",
            tool_calls = message_content$tool_calls
          )
          
          # Execute tools
          for (tool_call in message_content$tool_calls) {
            tool_name <- tool_call$`function`$name
            tool_args <- tool_call$`function`$arguments
            if (debug) cat(sprintf("[SARA Debug] Calling tool: %s\n", tool_name))
            tool_result <- execute_tool(tool_name, tool_args)
            if (debug) cat(sprintf("[SARA Debug] Tool %s completed\n", tool_name))
            
            messages[[length(messages) + 1]] <- list(
              role = "tool",
              content = tool_result
            )
          }
          next
        } else {
          return(list(
            content = message_content$content %||% "",
            messages = messages
          ))
        }
      }
      
      return(list(
        content = "Max iterations reached",
        messages = messages
      ))
    })

    # Render status message
    output$status_message <- shiny::renderUI({
      msg <- status_msg()
      if (nchar(msg) > 0) {
        shiny::tags$span(style = "color: #007bff;", msg)
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

    # When task completes, update chat
    shiny::observeEvent(sara_task$result(), {
      result <- sara_task$result()
      
      if (!is.null(result)) {
        # Update history with all new messages
        chat_history(result$messages)
        
        # Add final response if present
        if (!is.null(result$content) && nchar(result$content) > 0) {
          current_history <- chat_history()
          current_history[[length(current_history) + 1]] <- list(
            role = "assistant",
            content = result$content
          )
          chat_history(current_history)
        }
        
        status_msg("")
        shinyjs::enable("send")
      }
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

      status_msg("⏳ SARA is processing...")

      # Invoke the async task
      shinyjs::disable("send")
      sara_task$invoke(current_history, get_tools(), debug_enabled())
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
    
    # Toggle debug mode
    shiny::observeEvent(input$toggle_debug, {
      debug_enabled(!debug_enabled())
      if (debug_enabled()) {
        shiny::showNotification("Debug mode ON - check Background Jobs pane for details", type = "message", duration = 3)
      } else {
        shiny::showNotification("Debug mode OFF", type = "message", duration = 2)
      }
    })
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
