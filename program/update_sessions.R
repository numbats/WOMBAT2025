library(httr2)
req <- request("https://conf.nectric.com.au/api/events/wombat-2025/")

sessions <- req |> 
  req_url_path_append("schedules/latest/") |> 
  req_url_query(expand="slots.submission") |> 
  req_perform() |> 
  resp_body_json()

speakers <- req |> 
  req_url_path_append("speakers/") |> 
  req_perform() |> 
  resp_body_json()

rooms <- req |> 
  req_url_path_append("rooms/") |> 
  req_perform() |> 
  resp_body_json()

library(purrr)
library(tibble)
recurse_tibble <- function(x) {
  is_list_col <- lengths(x) > 1
  is_df_col <- map_lgl(x, \(y) !is.null(names(y)))
  tbl_cols <- names(x[is_list_col & is_df_col])
  x[tbl_cols] <- lapply(x[tbl_cols], recurse_tibble)
  lst_cols <- names(x[is_list_col & !is_df_col])
  x[lst_cols] <- lapply(x[lst_cols], \(x) list(unlist(x)))
  x[lengths(x) == 0] <- NA
  as_tibble(x)
}

library(dplyr)
library(tidyr)
speakers_tidy <- map_dfr(speakers$results,recurse_tibble) |> 
  unnest(submissions) |> 
  nest(.key = "speakers", .by = submissions)
sessions_tidy <- map_dfr(sessions$slots,recurse_tibble) |> 
  filter(!is.na(submission$code)) |> 
  transmute(
    start = as.POSIXct(start, format = "%Y-%m-%dT%H:%M:%S+10:00"),
    duration,
    time = format(start, "%B %d, %I:%M %p"),
    title = submission$title,
    abstract = submission$abstract,
    submissions = submission$code
  ) |> 
  left_join(speakers_tidy, by = "submissions")

write_session_qmd <- function(x, ...) {
  if(x$start < as.POSIXct("2025-09-30")) {
    dir <- "program/tutorials"
    x$register <- "[Register for this tutorial](https://events.humanitix.com/wombat-2025-day-1-tutorials)"
  } else {
    dir <- "program/workshops"
    x$register <- "[Register for the day 2 workshop](https://events.humanitix.com/wombat-2025-day-2-workshop)"
  }
  path <- xfun::with_ext(file.path(dir, x$submissions), "qmd")

  x <- as.list(x)
  
  # Generate short summary
  if(file.exists(path)) {
    x$description <- rmarkdown::yaml_front_matter(path)$description
  }
  if(is.null(x$description)) {
    chat <- ellmer::chat_openai(
      system_prompt = "Briefly summarise the key session topics in a plain text from the following abstract. The summary should start with a background details sentence, followed a sentence detailing the key topics of the session."
    )
    x$description <- chat$chat(x$abstract)
  }
  x$description <- gsub("\r\n", " ", x$description)
  x$description <- gsub("’", "'", x$description)
  
  x$yml <- yaml::as.yaml(
    list(
      pagetitle = paste("WOMBAT 2025:", x$title),
      date = format(x$start),
      title = x$title,
      description = x$description,
      # abstract = x$abstract,
      speaker = transpose(x$speakers[[1]][c("code", "name", "avatar_url")])
    )
  )
  
  x$speakers <- transpose(x$speakers[[1]])
  xfun::write_utf8(
    whisker::whisker.render(
      xfun::read_utf8("program/session_template.qmd"),
      x
    ),
    path
  )
}

# Workshops
sessions_tidy |> 
  rowwise() |> 
  group_walk(write_session_qmd)
