#' SARA Chat Interface
#'
#' Direct Ollama API integration with tool calling support for SARA
#' @param as_background Run as background job (default: TRUE in RStudio)
#' @export
sara_chat <- function(as_background = NULL) {

  # Run in foreground by default to enable live rstudioapi access
  if (is.null(as_background)) {
    as_background <- FALSE
  }

  # Null coalescing operator
  `%||%` <- function(a, b) if (is.null(a)) b else a

  # Debug logger (set inside server when debug is enabled)
  debug_logger <- NULL

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
      old_opts <- options(help_type = "text")
      on.exit(options(old_opts), add = TRUE)

      log_debug <- function(msg) {
        if (is.function(debug_logger)) debug_logger(msg)
      }

      query_encoded <- utils::URLencode(topic, reserved = TRUE)
      search_links <- paste(
        paste0("Search link (R Site Search): https://search.r-project.org/?P=", query_encoded, "&xDB=all&FMT=query"),
        paste0("Search link (rdrr.io): https://rdrr.io/search?q=", query_encoded),
        sep = "\n"
      )

      target_pkg <- ""
      target_topic <- topic
      if (grepl("::", topic, fixed = TRUE)) {
        parts <- strsplit(topic, "::", fixed = TRUE)[[1]]
        if (length(parts) >= 2) {
          target_pkg <- parts[1]
          target_topic <- parts[2]
        }
      }

      score_entry <- function(pkg, topic_val, title_val) {
        s <- 0
        if (nzchar(target_pkg) && tolower(pkg) == tolower(target_pkg)) s <- s + 5
        if (nzchar(target_topic) && tolower(topic_val) == tolower(target_topic)) s <- s + 10
        if (nzchar(target_topic) && nzchar(topic_val) &&
            grepl(tolower(target_topic), tolower(topic_val), fixed = TRUE)) s <- s + 3
        if (nzchar(target_topic) && nzchar(title_val) &&
            grepl(tolower(target_topic), tolower(title_val), fixed = TRUE)) s <- s + 1
        s
      }

      results <- utils::help.search(topic, agrep = FALSE, package = NULL)
      has_local <- !(is.null(results) || is.null(results$matches) || nrow(results$matches) == 0)

      if (has_local) {
        log_debug(paste0("search_r_help: local matches found for '", topic, "'."))
        matches <- as.data.frame(results$matches, stringsAsFactors = FALSE)
        get_col <- function(name) if (name %in% names(matches)) matches[[name]] else rep("", nrow(matches))

        pkg <- get_col("Package")
        topic_col <- get_col("Topic")
        title <- get_col("Title")
        type <- get_col("Type")

        max_show <- min(10, nrow(matches))
        lines <- character(max_show)
        for (i in seq_len(max_show)) {
          pkg_part <- if (nzchar(pkg[i])) paste0(pkg[i], "::") else ""
          title_part <- if (nzchar(title[i])) paste0(" - ", title[i]) else ""
          type_part <- if (nzchar(type[i])) paste0(" [", type[i], "]") else ""
          lines[i] <- paste0(i, ". ", pkg_part, topic_col[i], title_part, type_part)
        }

        scores <- mapply(score_entry, pkg, topic_col, title)
        best_idx <- if (length(scores) > 0) which.max(scores) else 1
        top_topic <- if (length(topic_col) > 0) topic_col[best_idx] else ""
        top_pkg <- if (length(pkg) > 0) pkg[best_idx] else ""
        top_help <- if (nzchar(top_pkg)) {
          paste0("help(\"", top_topic, "\", package = \"", top_pkg, "\")")
        } else if (nzchar(top_topic)) {
          paste0("help(\"", top_topic, "\")")
        } else {
          ""
        }

        direct_line <- if (nzchar(top_help)) {
          paste0("Direct help for top match (local): ", top_help)
        } else {
          "Direct help for top match (local): (not available)"
        }

        excerpt <- NULL
        if (nzchar(top_pkg) && nzchar(top_topic)) {
          candidate_urls <- c(
            paste0("https://search.r-project.org/CRAN/refmans/", top_pkg, "/html/", top_topic, ".html"),
            paste0("https://search.r-project.org/R/refmans/", top_pkg, "/html/", top_topic, ".html")
          )
          for (u in candidate_urls) {
            excerpt_try <- fetch_help_page(u, focus = topic, max_chars = 1200)
            if (!grepl("^Error fetching help page", excerpt_try) &&
                !grepl("^No readable text found", excerpt_try)) {
              excerpt <- excerpt_try
              break
            }
          }
        }

        parts <- c(
          "Help search results (local summary; Help viewer not opened):",
          paste(lines, collapse = "\n"),
          direct_line
        )
        if (!is.null(excerpt)) parts <- c(parts, excerpt)
        parts <- c(
          parts,
          search_links,
          "To open full docs manually, use ?topic or help(\"topic\", package = \"pkg\")."
        )
        return(paste(parts, collapse = "\n"))
      }

      # Fallback: online R Site Search (covers all packages)
      log_debug(paste0("search_r_help: no local matches; attempting online search for '", topic, "'."))
      online_result <- tryCatch({
        resp <- httr2::request("https://search.r-project.org/") |>
          httr2::req_url_query(P = topic, xDB = "all", FMT = "query") |>
          httr2::req_perform()
        status <- httr2::resp_status(resp)
        log_debug(paste0("search_r_help: online search HTTP status ", status, " for '", topic, "'."))
        if (status >= 400) stop(paste("HTTP", status))

        resp_body <- httr2::resp_body_string(resp)
        raw_lines <- strsplit(resp_body, "\n", fixed = TRUE)[[1]]
        entries <- list()

        for (ln in raw_lines) {
          m <- regexec("<td><b><a href=\"([^\"]+)\">([^<]+)</a></b><br>", ln)
          parts <- regmatches(ln, m)[[1]]
          if (length(parts) > 0) {
            href <- parts[2]
            title_text <- parts[3]
            pkg <- ""
            topic_val <- ""
            if (grepl("^/CRAN/refmans/[^/]+/html/[^/]+\\.html$", href)) {
              pkg <- sub("^/CRAN/refmans/([^/]+)/html/.*$", "\\1", href)
              topic_val <- sub("^/CRAN/refmans/[^/]+/html/([^/]+)\\.html$", "\\1", href)
            }
            title_clean <- sub("^R:\\s*", "", title_text)
            entries[[length(entries) + 1]] <- list(
              pkg = pkg,
              topic = topic_val,
              title = title_clean,
              href = href
            )
          }
        }

        if (length(entries) == 0) return(NULL)

        scores <- vapply(entries, function(e) {
          score_entry(e$pkg, e$topic, e$title)
        }, numeric(1))

        max_show <- min(10, length(entries))
        out_lines <- character(max_show)
        for (i in seq_len(max_show)) {
          e <- entries[[i]]
          pkg_part <- if (nzchar(e$pkg)) paste0(e$pkg, "::") else ""
          topic_part <- if (nzchar(e$topic)) e$topic else e$title
          title_part <- if (nzchar(e$title) && nzchar(e$topic)) paste0(" - ", e$title) else ""
          out_lines[i] <- paste0(i, ". ", pkg_part, topic_part, title_part)
        }

        ordered_idx <- order(scores, decreasing = TRUE)
        best_idx <- if (length(ordered_idx) > 0) ordered_idx[1] else 1
        best <- entries[[best_idx]]
        best_score <- if (length(scores) > 0) scores[[best_idx]] else 0
        top_link <- if (nzchar(best$href)) {
          paste0("https://search.r-project.org", best$href)
        } else {
          ""
        }

        direct_line <- if (nzchar(top_link)) {
          paste0("Direct help for top match (online): ", top_link)
        } else {
          "Direct help for top match (online): (not available)"
        }

        excerpts <- character(0)
        if (length(ordered_idx) > 0) {
          max_excerpts <- if (best_score < 8 && length(ordered_idx) > 1) 2 else 1
          used_links <- character(0)
          for (i in ordered_idx) {
            e <- entries[[i]]
            if (!nzchar(e$href)) next
            link <- paste0("https://search.r-project.org", e$href)
            if (link %in% used_links) next
            excerpt_try <- fetch_help_page(link, focus = topic, max_chars = 800)
            if (!grepl("^Error fetching help page", excerpt_try) &&
                !grepl("^No readable text found", excerpt_try)) {
              excerpts <- c(excerpts, excerpt_try)
              used_links <- c(used_links, link)
            }
            if (length(excerpts) >= max_excerpts) break
          }
        }

        log_debug(paste0("search_r_help: online search returned ", length(entries), " result(s)."))
        parts <- c(
          "Help search results (online summary; Help viewer not opened):",
          paste(out_lines, collapse = "\n"),
          direct_line
        )
        if (length(excerpts) > 0) parts <- c(parts, excerpts)
        parts <- c(
          parts,
          search_links,
          "Note: install the package to access local help."
        )
        paste(parts, collapse = "\n")
      }, error = function(e) {
        log_debug(paste0("search_r_help: online search failed for '", topic, "': ", e$message))
        NULL
      })

      if (!is.null(online_result)) {
        return(online_result)
      }

      return(paste(
        paste("No help found for:", topic),
        search_links,
        sep = "\n"
      ))
    }, error = function(e) {
      return(paste("Error searching help:", e$message))
    })
  }

  # 1b. Fetch and summarize an R help page (online)
  fetch_help_page <- function(url, focus = NULL, max_chars = 2400) {
    tryCatch({
      log_debug <- function(msg) {
        if (is.function(debug_logger)) debug_logger(msg)
      }
      log_debug(paste0("fetch_help_page: fetching ", url))

      resp <- httr2::request(url) |>
        httr2::req_perform()
      status <- httr2::resp_status(resp)
      log_debug(paste0("fetch_help_page: HTTP status ", status))
      if (status >= 400) {
        return(paste("Error fetching help page (HTTP", status, "):", url))
      }

      html <- httr2::resp_body_string(resp)
      # Strip scripts/styles and tags
      html <- gsub("<script[\\s\\S]*?</script>", " ", html, ignore.case = TRUE)
      html <- gsub("<style[\\s\\S]*?</style>", " ", html, ignore.case = TRUE)
      text <- gsub("<[^>]+>", " ", html)
      # Decode common HTML entities
      text <- gsub("&quot;", "\"", text, fixed = TRUE)
      text <- gsub("&amp;", "&", text, fixed = TRUE)
      text <- gsub("&lt;", "<", text, fixed = TRUE)
      text <- gsub("&gt;", ">", text, fixed = TRUE)
      text <- gsub("&nbsp;", " ", text, fixed = TRUE)
      # Normalize whitespace
      text <- gsub("[ \t]+", " ", text)
      text <- gsub("\r", "\n", text)
      text <- gsub("\n{2,}", "\n", text)
      lines <- trimws(unlist(strsplit(text, "\n", fixed = TRUE)))
      lines <- lines[nzchar(lines)]

      if (length(lines) == 0) {
        return(paste("No readable text found at:", url))
      }

      headings <- c("Description", "Usage", "Arguments", "Value", "Details", "Examples", "See Also")
      idx <- which(lines %in% headings)
      picked <- character(0)

      if (length(idx) > 0) {
        for (i in seq_along(idx)) {
          start <- idx[i] + 1
          end <- if (i < length(idx)) idx[i + 1] - 1 else min(length(lines), start + 40)
          section <- lines[start:end]
          if (length(section) > 0) {
            picked <- c(picked, headings[which(lines[idx[i]] == headings)], section)
          }
          if (length(picked) > 200) break
        }
      } else {
        picked <- head(lines, 80)
      }

      # Apply focus filter lightly (keep lines containing focus keywords)
      if (!is.null(focus) && nzchar(focus)) {
        focus_terms <- unique(unlist(strsplit(tolower(focus), "[^a-z0-9_]+")))
        focus_terms <- focus_terms[nzchar(focus_terms)]
        if (length(focus_terms) > 0) {
          keep <- vapply(picked, function(l) {
            any(vapply(focus_terms, function(t) grepl(t, tolower(l), fixed = TRUE), logical(1)))
          }, logical(1))
          if (any(keep)) {
            picked <- picked[keep]
          }
        }
      }

      out <- paste(picked, collapse = "\n")
      if (nchar(out) > max_chars) {
        out <- substr(out, 1, max_chars)
        out <- paste0(out, "\n[truncated]")
      }

      return(paste(
        "Help page excerpt (parsed text):",
        out,
        paste0("Source: ", url),
        sep = "\n"
      ))
    }, error = function(e) {
      return(paste("Error fetching help page:", e$message))
    })
  }

  # 2. Search R extensions/packages
  search_r_packages <- function(keyword) {
    tryCatch({
      old_opts <- options(help_type = "text")
      on.exit(options(old_opts), add = TRUE)

      query_encoded <- utils::URLencode(keyword, reserved = TRUE)
      search_links <- paste(
        paste0("Search link (R Site Search): https://search.r-project.org/?P=", query_encoded, "&xDB=all&FMT=query"),
        paste0("Search link (rdrr.io): https://rdrr.io/search?q=", query_encoded),
        sep = "\n"
      )

      results <- utils::help.search(keyword, agrep = FALSE, package = NULL)
      if (is.null(results) || is.null(results$matches) || nrow(results$matches) == 0) {
        return(paste(
          paste("No packages found for:", keyword),
          search_links,
          sep = "\n"
        ))
      }

      matches <- as.data.frame(results$matches, stringsAsFactors = FALSE)
      if (!"Package" %in% names(matches)) {
        return(paste(
          paste("No packages found for:", keyword),
          search_links,
          sep = "\n"
        ))
      }

      pkg_counts <- sort(table(matches$Package), decreasing = TRUE)
      pkg_names <- names(pkg_counts)
      max_show <- min(10, length(pkg_names))
      lines <- character(max_show)
      for (i in seq_len(max_show)) {
        lines[i] <- paste0(i, ". ", pkg_names[i], " (", pkg_counts[[i]], " topic", if (pkg_counts[[i]] == 1) "" else "s", ")")
      }

      top_pkg <- if (length(pkg_names) > 0) pkg_names[1] else ""
      direct_line <- if (nzchar(top_pkg)) {
        paste0("Direct package page (top match): https://cran.r-project.org/package=", top_pkg)
      } else {
        "Direct package page (top match): (not available)"
      }

      return(paste(
        "Package search results (local summary; Help viewer not opened):",
        paste(lines, collapse = "\n"),
        direct_line,
        search_links,
        sep = "\n"
      ))
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
        # Fallback to source editor context (sometimes more reliable in RStudio Server)
        context <- rstudioapi::getSourceEditorContext()
      }

      if (is.null(context) || is.null(context$contents) || length(context$contents) == 0) {
        # Final fallback: scan open documents
        docs <- tryCatch(rstudioapi::documentList(), error = function(e) NULL)
        if (!is.null(docs) && length(docs) > 0) {
          for (doc in docs) {
            if (!is.null(doc$contents) && length(doc$contents) > 0) {
              context <- doc
              break
            }
          }
        }
      }

      if (is.null(context) || is.null(context$contents) || length(context$contents) == 0) {
        return("No active R script found (make sure an R script tab is focused)")
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
          name = "fetch_help_page",
          description = "Fetch and extract readable text from an online R help page URL and return a short excerpt",
          parameters = list(
            type = "object",
            properties = list(
              url = list(
                type = "string",
                description = "Full URL of the help page to fetch"
              ),
              focus = list(
                type = "string",
                description = "Optional: a short phrase about what the user wants; used to filter relevant lines"
              ),
              max_chars = list(
                type = "integer",
                description = "Maximum number of characters to return (default: 2400)"
              )
            ),
            required = list("url")
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
                description = "Description of the analysis task and expected output format. Must specify both the task and the output values clearly."
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
      "fetch_help_page" = fetch_help_page(
        url = tool_args$url,
        focus = tool_args$focus %||% NULL,
        max_chars = tool_args$max_chars %||% 2400
      ),
      "search_r_packages" = search_r_packages(tool_args$keyword),
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

ROLE
You are a helpful R assistant focused on tidyverse and tidymodels.

REFERENCES
Use 'Tidy Modeling with R' (https://www.tmwr.org/) and 'R for Data Science' (https://r4ds.had.co.nz/) as primary references.

PREFERRED PACKAGES
tidyverse: readr, ggplot2, dplyr, tidyr
tidymodels: recipes, parsnip, yardstick, workflows, broom

OUTPUT
- Default: code only, no explanations.
- If the user asks for a script or code, return a complete, runnable R script.
- If the user asks \"how can I\" (or similar), show the relevant function/code and add a brief explanation.

TOOLS
Available tools:
1. search_r_help(topic)
2. search_r_packages(keyword)
3. fetch_help_page(url, focus, max_chars)
4. run_batch_classify()

Use search_r_help() / search_r_packages() only when you are unsure about an R function or package.

HELP PAGES
If the user asks for help or details about a function/package, you must:
1) Use search_r_help() to find candidates.
2) Read the most relevant help page excerpt (use fetch_help_page()).
3) Provide a 1-2 sentence concept intro if the user asked a general \"what is\" or broad topic (e.g., \"machine learning models\").
4) Summarize the excerpt in a short paragraph (2–4 sentences) plus 4–8 bullets tailored to the user’s question.
5) If the excerpt does not fit the use-case, search again with a refined query and repeat.
6) Provide a short coding example where applicable.
Always include the best matching help link, but do not dump long excerpts.

USER CONTEXT
The user can share their R script or dataframes via /script or /data (or the UI buttons). Use that context when provided.

SEMANTIC ANALYSIS (TEXT IN DATAFRAMES)
Use run_batch_classify() only when the user asks for semantic analysis (classify/score/categorize by meaning).
Steps:
1. Ask for /data if not already provided.
2. Call run_batch_classify() with:
   - df_name
   - column_name
   - task_prompt (must specify the task AND exact output values)
   - result_column (name for output)

CRITICAL: task_prompt must define explicit output values (e.g., \"Return 1 if urgent, otherwise 0\"). Do not use keyword-based regex/grepl for semantic tasks."
  }

  # ============================================================================
  # OLLAMA API CALL WITH TOOL SUPPORT (with status callback)
  # ============================================================================

  call_ollama_with_tools <- function(messages, tools = NULL, max_iterations = 3, status_callback = NULL, debug = FALSE, debug_callback = NULL) {
    iteration <- 0
    tools_used <- FALSE

    finalize_without_tools <- function(final_messages) {
      if (!is.null(status_callback)) {
        status_callback("Finalizing response...")
      }
      tryCatch({
        final_messages[[length(final_messages) + 1]] <- list(
          role = "system",
          content = "Tool calls are complete. Provide the final response now. Do not call tools."
        )
        body <- list(
          model = "sara",
          messages = final_messages,
          stream = FALSE
        )
        response <- httr2::request("http://127.0.0.1:11434/api/chat") |>
          httr2::req_body_json(body, auto_unbox = TRUE) |>
          httr2::req_perform() |>
          httr2::resp_body_json()
        message_content <- response$message
        thinking <- message_content$thinking %||% message_content$reasoning %||% NULL
        if (!is.null(thinking) && !nzchar(trimws(thinking))) thinking <- NULL
        return(list(
          content = message_content$content %||% "Maximum tool calling iterations reached.",
          thinking = thinking,
          messages = messages
        ))
      }, error = function(e) {
        return(list(
          content = "Maximum tool calling iterations reached.",
          messages = messages
        ))
      })
    }

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

        # Add tools only for the first tool-eligible pass
        if (!tools_used && !is.null(tools) && length(tools) > 0) {
          body$tools <- tools
        }

        response <- httr2::request("http://127.0.0.1:11434/api/chat") |>
          httr2::req_body_json(body, auto_unbox = TRUE) |>
          httr2::req_perform() |>
          httr2::resp_body_json()

        message_content <- response$message
        thinking <- message_content$thinking %||% message_content$reasoning %||% NULL

        # Extract <think>...</think> if model embeds it in content
        if (is.null(thinking) && !is.null(message_content$content) &&
            grepl("<think>", message_content$content, fixed = TRUE)) {
          think_match <- regmatches(
            message_content$content,
            regexec("(?s)<think>(.*?)</think>", message_content$content, perl = TRUE)
          )[[1]]
          if (length(think_match) >= 2) {
            thinking <- trimws(think_match[2])
            message_content$content <- trimws(gsub("(?s)<think>.*?</think>", "", message_content$content, perl = TRUE))
          }
        }
        if (!is.null(thinking) && !nzchar(trimws(thinking))) {
          thinking <- NULL
        }

        # Check if model wants to call a tool
        if (!is.null(message_content$tool_calls) && length(message_content$tool_calls) > 0) {
          if (tools_used) {
            # Prevent repeated tool loops: finalize without more tools
            return(finalize_without_tools(messages))
          }

          # Add assistant's tool call message to history
          messages[[length(messages) + 1]] <- list(
            role = "assistant",
            content = "",
            tool_calls = message_content$tool_calls,
            thinking = thinking %||% NULL
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

          tools_used <- TRUE
          # Continue loop to get final response
          next

        } else {
          # No tool calls, return final response
          if (!is.null(status_callback)) {
            status_callback("Generating response...")
          }

          return(list(
            content = message_content$content %||% "",
            thinking = thinking %||% NULL,
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

    # Max iterations reached: attempt a final response without tools
    return(finalize_without_tools(messages))
  }

  # ============================================================================
  # CONTEXT CAPTURE AT STARTUP (while rstudioapi is available)
  # ============================================================================

  # Capture script and dataframes at startup - these will be refreshed on button click
  cached_script <- list(content = NULL, name = NULL, time = NULL)
  cached_dataframes <- list(content = NULL, time = NULL)

  # Try to capture script at startup
  tryCatch({
    if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
      context <- rstudioapi::getActiveDocumentContext()
      if (!is.null(context) && !is.null(context$contents) && length(context$contents) > 0) {
        cached_script$content <- paste(context$contents, collapse = "\n")
        cached_script$name <- ifelse(nzchar(context$path), basename(context$path), "Untitled")
        cached_script$time <- Sys.time()
      }
    }
  }, error = function(e) NULL)

  # Try to capture dataframes at startup
  tryCatch({
    cached_dataframes$content <- get_user_dataframes()
    cached_dataframes$time <- Sys.time()
  }, error = function(e) NULL)

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
        details.sara-intermediate > summary,
        details.sara-tool-output > summary {
          color: #8a8a8a;
          font-size: 0.85em;
          opacity: 0.85;
          cursor: pointer;
          list-style: none;
        }
        details.sara-intermediate > summary::-webkit-details-marker,
        details.sara-tool-output > summary::-webkit-details-marker {
          display: none;
        }
        details.sara-intermediate,
        details.sara-tool-output {
          margin: 6px 0;
        }
        details.sara-intermediate[open] {
          padding: 6px;
          background: #f7f7ff;
          border: 1px solid #d8d8ff;
          border-radius: 4px;
        }
        details.sara-tool-output[open] {
          padding: 8px;
          background: #f1f3f5;
          border: 1px dashed #bbb;
          border-radius: 5px;
        }
        details.sara-intermediate:not([open]),
        details.sara-tool-output:not([open]) {
          padding: 0;
          border: none;
          background: transparent;
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
        shiny::actionButton("add_script", "📄 Add Script", class = "btn-primary"),
        shiny::actionButton("add_data", "📊 Add Data", class = "btn-primary", style = "margin-left: 10px;"),
        shiny::actionButton("clear_chat", "🗑️ Clear Chat", class = "btn-warning", style = "margin-left: 20px;"),
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
      shiny::column(12,
        shiny::uiOutput("pending_context_indicator")
      )
    ),

    shiny::fluidRow(
      shiny::column(10,
        shiny::textInput("user_input", NULL,
                        placeholder = "Ask SARA anything... Use /script or /data to add context, or click the buttons above.",
                        width = "100%")
      ),
      shiny::column(2,
        shiny::actionButton("send", "Send", class = "btn-success", width = "100%")
      )
    ),

    shiny::tags$script(shiny::HTML("
      function submitUserInput() {
        var val = $('#user_input').val();
        if (window.Shiny && Shiny.setInputValue) {
          Shiny.setInputValue('user_input_submit', val, {priority: 'event'});
        }
      }

      $(document).on('keydown', '#user_input', function(e) {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault();
          submitUserInput();
        }
      });

      $(document).on('click', '#send', function() {
        submitUserInput();
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

    # Expose debug logger to helper functions
    debug_logger <<- append_debug

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

    # Pending context to be added to next message
    pending_context <- shiny::reactiveVal(NULL)

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

    # Render pending context indicator (sticky badge above input)
    output$pending_context_indicator <- shiny::renderUI({
      ctx <- pending_context()
      if (!is.null(ctx)) {
        # Determine if it's script or data
        if (grepl("USER'S R SCRIPT", ctx)) {
          label <- "📄 Script attached"
          bg_color <- "#e3f2fd"
          border_color <- "#2196f3"
        } else {
          label <- "📊 Data attached"
          bg_color <- "#e8f5e9"
          border_color <- "#4caf50"
        }
        shiny::div(
          style = sprintf(
            "display: inline-flex; align-items: center; padding: 4px 10px; margin-bottom: 5px; background: %s; border: 1px solid %s; border-radius: 15px; font-size: 0.85em;",
            bg_color, border_color
          ),
          shiny::tags$span(label),
          shiny::actionLink(
            "clear_pending_context",
            shiny::tags$span(style = "margin-left: 8px; color: #999; font-weight: bold;", "✕"),
            style = "text-decoration: none;"
          )
        )
      }
    })

    # Clear pending context when X is clicked
    shiny::observeEvent(input$clear_pending_context, {
      pending_context(NULL)
      shiny::showNotification("Context cleared.", type = "message", duration = 2)
    })

    # Render chat history
    output$chat_history <- shiny::renderUI({
      messages <- chat_history()

      if (length(messages) <= 1) {
        return(shiny::p(style = "color: #999;",
                       "Start chatting with SARA! Use /script or /data (or the buttons above) to share your code or data with her."))
      }

      # Skip system message
      display_messages <- messages[-1]

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

          thinking_info <- NULL
          if (!is.null(msg$thinking) && nzchar(trimws(msg$thinking))) {
            thinking_text <- trimws(msg$thinking)
            if (nchar(thinking_text) > 2000) {
              thinking_text <- paste0(substr(thinking_text, 1, 2000), "\n[truncated]")
            }
            thinking_info <- shiny::tags$details(
              class = "sara-intermediate",
              shiny::tags$summary("Intermediate"),
              shiny::tags$div(
                style = "margin-top: 6px;",
                shiny::tags$pre(style = "margin: 4px 0; white-space: pre-wrap; font-size: 0.85em;", thinking_text)
              )
            )
          }

          shiny::div(
            style = "margin: 10px 0; padding: 10px; background: #fff; border: 1px solid #ddd; border-radius: 5px;",
            shiny::tags$strong("SARA:"),
            tool_info,
            thinking_info,
            if (!is.null(msg$content) && nzchar(trimws(msg$content))) {
              shiny::tags$pre(style = "margin: 5px 0; white-space: pre-wrap;", msg$content)
            }
          )
        } else if (msg$role == "tool") {
          if (!is.null(msg$content) && nzchar(trimws(msg$content))) {
            shiny::tags$details(
              class = "sara-tool-output",
              shiny::tags$summary("Tool output"),
              shiny::tags$div(
                style = "margin-top: 6px;",
                shiny::tags$pre(style = "margin: 5px 0; white-space: pre-wrap; font-size: 0.9em;", msg$content)
              )
            )
          }
        }
      })

      shiny::tagList(ui_messages)
    })

    # Send message
    shiny::observeEvent(input$user_input_submit, {
      shiny::req(input$user_input_submit)
      user_msg <- input$user_input_submit

      if (nchar(trimws(user_msg)) == 0) return()

      # Handle /script command
      if (grepl("^/script\\b", trimws(user_msg), ignore.case = TRUE)) {
        script_content <- NULL
        script_name <- "Unknown"

        # Try to get fresh script
        tryCatch({
          if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
            context <- rstudioapi::getActiveDocumentContext()
            if (!is.null(context) && !is.null(context$contents) && length(context$contents) > 0) {
              script_content <- paste(context$contents, collapse = "\n")
              script_name <- ifelse(nzchar(context$path), basename(context$path), "Untitled")
              cached_script$content <<- script_content
              cached_script$name <<- script_name
              cached_script$time <<- Sys.time()
            }
          }
        }, error = function(e) NULL)

        # Fall back to cached
        if (is.null(script_content) && !is.null(cached_script$content)) {
          script_content <- cached_script$content
          script_name <- cached_script$name %||% "Cached Script"
        }

        if (!is.null(script_content)) {
          # Remove /script from message and prepend context
          remaining_msg <- trimws(sub("^/script\\s*", "", user_msg, ignore.case = TRUE))
          if (nchar(remaining_msg) == 0) remaining_msg <- "Please review my script."
          user_msg <- sprintf(
            "[USER'S R SCRIPT: %s]\n```r\n%s\n```\n\n%s",
            script_name, script_content, remaining_msg
          )
        } else {
          shiny::showNotification("No script found.", type = "error", duration = 3)
          return()
        }
      }

      # Handle /data command
      if (grepl("^/data\\b", trimws(user_msg), ignore.case = TRUE)) {
        data_content <- NULL

        # Try to get fresh dataframes
        tryCatch({
          data_content <- get_user_dataframes()
          if (!is.null(data_content) && !grepl("No dataframes found", data_content)) {
            cached_dataframes$content <<- data_content
            cached_dataframes$time <<- Sys.time()
          } else {
            data_content <- NULL
          }
        }, error = function(e) NULL)

        # Fall back to cached
        if (is.null(data_content) && !is.null(cached_dataframes$content) &&
            !grepl("No dataframes found", cached_dataframes$content)) {
          data_content <- cached_dataframes$content
        }

        if (!is.null(data_content) && !grepl("No dataframes found", data_content)) {
          remaining_msg <- trimws(sub("^/data\\s*", "", user_msg, ignore.case = TRUE))
          if (nchar(remaining_msg) == 0) remaining_msg <- "Please review my data."
          user_msg <- sprintf(
            "[USER'S R DATAFRAMES]\n%s\n\n%s",
            data_content, remaining_msg
          )
        } else {
          shiny::showNotification("No dataframes found.", type = "error", duration = 3)
          return()
        }
      }

      # Include any pending context from button clicks
      ctx <- pending_context()
      if (!is.null(ctx)) {
        user_msg <- paste0(ctx, "\n\n", user_msg)
        pending_context(NULL)  # Clear pending context
      }

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
          content = result$content,
          thinking = result$thinking %||% NULL
        )
        chat_history(current_history)
      }

      status_msg("")
      shinyjs::hide("sara_spinner")
      shinyjs::enable("user_input")
      shinyjs::enable("send")
    })

    # Add Script button - captures and queues script context
    shiny::observeEvent(input$add_script, {
      script_content <- NULL
      script_name <- "Unknown"

      # Try to get fresh script from rstudioapi
      tryCatch({
        if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
          context <- rstudioapi::getActiveDocumentContext()
          if (!is.null(context) && !is.null(context$contents) && length(context$contents) > 0) {
            script_content <- paste(context$contents, collapse = "\n")
            script_name <- ifelse(nzchar(context$path), basename(context$path), "Untitled")
            # Update cache
            cached_script$content <<- script_content
            cached_script$name <<- script_name
            cached_script$time <<- Sys.time()
          }
        }
      }, error = function(e) NULL)

      # Fall back to cached script
      if (is.null(script_content) && !is.null(cached_script$content)) {
        script_content <- cached_script$content
        script_name <- cached_script$name %||% "Cached Script"
        shiny::showNotification(
          paste0("Using cached script from ", format(cached_script$time, "%H:%M:%S")),
          type = "warning", duration = 3
        )
      }

      if (!is.null(script_content)) {
        context_text <- sprintf(
          "[USER'S R SCRIPT: %s]\n```r\n%s\n```",
          script_name, script_content
        )
        pending_context(context_text)
        shiny::showNotification(
          paste0("📄 Script '", script_name, "' ready to send. Type your question and press Send."),
          type = "message", duration = 3
        )
        # Focus on input
        shinyjs::runjs("$('#user_input').focus();")
      } else {
        shiny::showNotification(
          "No script found. Please open an R script in RStudio first.",
          type = "error", duration = 3
        )
      }
    })

    # Add Data button - captures and queues dataframe context
    shiny::observeEvent(input$add_data, {
      data_content <- NULL

      # Try to get fresh dataframes
      tryCatch({
        data_content <- get_user_dataframes()
        if (!is.null(data_content) && !grepl("No dataframes found", data_content)) {
          # Update cache
          cached_dataframes$content <<- data_content
          cached_dataframes$time <<- Sys.time()
        } else {
          data_content <- NULL
        }
      }, error = function(e) NULL)

      # Fall back to cached dataframes
      if (is.null(data_content) && !is.null(cached_dataframes$content) &&
          !grepl("No dataframes found", cached_dataframes$content)) {
        data_content <- cached_dataframes$content
        shiny::showNotification(
          paste0("Using cached data from ", format(cached_dataframes$time, "%H:%M:%S")),
          type = "warning", duration = 3
        )
      }

      if (!is.null(data_content) && !grepl("No dataframes found", data_content)) {
        context_text <- sprintf("[USER'S R DATAFRAMES]\n%s", data_content)
        pending_context(context_text)
        shiny::showNotification(
          "📊 Dataframe info ready to send. Type your question and press Send.",
          type = "message", duration = 3
        )
        # Focus on input
        shinyjs::runjs("$('#user_input').focus();")
      } else {
        shiny::showNotification(
          "No dataframes found in your R environment.",
          type = "error", duration = 3
        )
      }
    })

    # Clear chat
    shiny::observeEvent(input$clear_chat, {
      chat_history(list(
        list(role = "system", content = get_system_prompt())
      ))
      pending_context(NULL)
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
