#' Escape/quote a string.
#'
#' @param x An object to escape. Existing sql vectors will be left as is,
#'   character vectors are escaped with single quotes, numeric vectors have
#'   trailing `.0` added if they're whole numbers, identifiers are
#'   escaped with double quotes.
#' @param parens,collapse Controls behaviour when multiple values are supplied.
#'   `parens` should be a logical flag, or if `NA`, will wrap in
#'   parens if length > 1.
#'
#'   Default behaviour: lists are always wrapped in parens and separated by
#'   commas, identifiers are separated by commas and never wrapped,
#'   atomic vectors are separated by spaces and wrapped in parens if needed.
#' @param con Database connection. If not specified, uses SQL 92 conventions.
#' @rdname escape
#' @export
#' @examples
#' # Doubles vs. integers
#' escape(1:5)
#' escape(c(1, 5.4))
#'
#' # String vs known sql vs. sql identifier
#' escape("X")
#' escape(sql("X"))
#' escape(ident("X"))
#'
#' # Escaping is idempotent
#' escape("X")
#' escape(escape("X"))
#' escape(escape(escape("X")))
escape <- function(x, parens = NA, collapse = " ", con = NULL) {
  UseMethod("escape")
}

#' @export
escape.ident <- function(x, parens = FALSE, collapse = ", ", con = NULL) {
  y <- sql_escape_ident(con, x)
  sql_vector(names_to_as(y, names2(x), con = con), parens, collapse)
}

#' @export
escape.ident_q <- function(x, parens = FALSE, collapse = ", ", con = NULL) {
  sql_vector(names_to_as(x, names2(x), con = con), parens, collapse)
}

#' @export
escape.logical <- function(x, parens = NA, collapse = ", ", con = NULL) {
  sql_vector(sql_escape_logical(con, x), parens, collapse, con = con)
}

#' @export
escape.factor <- function(x, parens = NA, collapse = ", ", con = NULL) {
  x <- as.character(x)
  escape.character(x, parens = parens, collapse = collapse, con = con)
}

#' @export
escape.Date <- function(x, parens = NA, collapse = ", ", con = NULL) {
  x <- as.character(x)
  escape.character(x, parens = parens, collapse = collapse, con = con)
}

#' @export
escape.POSIXt <- function(x, parens = NA, collapse = ", ", con = NULL) {
  x <- strftime(x, "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC")
  escape.character(x, parens = parens, collapse = collapse, con = con)
}

#' @export
escape.character <- function(x, parens = NA, collapse = ", ", con = NULL) {
  sql_vector(sql_escape_string(con, x), parens, collapse, con = con)
}

#' @export
escape.double <- function(x, parens = NA, collapse = ", ", con = NULL) {
  out <- ifelse(is.wholenumber(x), sprintf("%.1f", x), as.character(x))

  # Special values
  out[is.na(x)] <- "NULL"
  inf <- is.infinite(x)
  out[inf & x > 0] <- "'Infinity'"
  out[inf & x < 0] <- "'-Infinity'"

  sql_vector(out, parens, collapse)
}

#' @export
escape.integer <- function(x, parens = NA, collapse = ", ", con = NULL) {
  x[is.na(x)] <- "NULL"
  sql_vector(x, parens, collapse)
}

#' @export
escape.integer64 <- function(x, parens = NA, collapse = ", ", con = NULL) {
  x <- as.character(x)
  x[is.na(x)] <- "NULL"
  sql_vector(x, parens, collapse)
}

#' @export
escape.NULL <- function(x, parens = NA, collapse = " ", con = NULL) {
  sql("NULL")
}

#' @export
escape.sql <- function(x, parens = NULL, collapse = NULL, con = NULL) {
  sql_vector(x, isTRUE(parens), collapse, con = con)
}

#' @export
escape.list <- function(x, parens = TRUE, collapse = ", ", con = NULL) {
  pieces <- vapply(x, escape, character(1), con = con)
  sql_vector(pieces, parens, collapse)
}

#' @export
#' @rdname escape
sql_vector <- function(x, parens = NA, collapse = " ", con = NULL) {
  if (length(x) == 0) {
    if (!is.null(collapse)) {
      return(if (isTRUE(parens)) sql("()") else sql(""))
    } else {
      return(sql())
    }
  }

  if (is.na(parens)) {
    parens <- length(x) > 1L
  }

  x <- names_to_as(x, con = con)
  x <- paste(x, collapse = collapse)
  if (parens) x <- paste0("(", x, ")")
  sql(x)
}

names_to_as <- function(x, names = names2(x), con = NULL) {
  if (length(x) == 0) {
    return(character())
  }

  names_esc <- sql_escape_ident(con, names)
  as <- ifelse(names == "" | names_esc == x, "", paste0(" AS ", names_esc))

  paste0(x, as)
}


#' Build a SQL string.
#'
#' This is a convenience function that should prevent sql injection attacks
#' (which in the context of dplyr are most likely to be accidental not
#' deliberate) by automatically escaping all expressions in the input, while
#' treating bare strings as sql. This is unlikely to prevent any serious
#' attack, but should make it unlikely that you produce invalid sql.
#'
#' @param ... input to convert to SQL. Use [sql()] to preserve
#'   user input as is (dangerous), and [ident()] to label user
#'   input as sql identifiers (safe)
#' @param .env the environment in which to evalute the arguments. Should not
#'   be needed in typical use.
#' @param con database connection; used to select correct quoting characters.
#' @export
#' @examples
#' build_sql("SELECT * FROM TABLE")
#' x <- "TABLE"
#' build_sql("SELECT * FROM ", x)
#' build_sql("SELECT * FROM ", ident(x))
#' build_sql("SELECT * FROM ", sql(x))
#'
#' # http://xkcd.com/327/
#' name <- "Robert'); DROP TABLE Students;--"
#' build_sql("INSERT INTO Students (Name) VALUES (", name, ")")
build_sql <- function(..., .env = parent.frame(), con = sql_current_con()) {
  escape_expr <- function(x) {
    # If it's a string, leave it as is
    if (is.character(x)) return(x)

    val <- eval_bare(x, .env)
    # Skip nulls, so you can use if statements like in paste
    if (is.null(val)) return("")

    escape(val, con = con)
  }

  pieces <- vapply(dots(...), escape_expr, character(1))
  sql(paste0(pieces, collapse = ""))
}

#' Helper function for quoting sql elements.
#'
#' If the quote character is present in the string, it will be doubled.
#' `NA`s will be replaced with NULL.
#'
#' @export
#' @param x Character vector to escape.
#' @param quote Single quoting character.
#' @export
#' @keywords internal
#' @examples
#' sql_quote("abc", "'")
#' sql_quote("I've had a good day", "'")
#' sql_quote(c("abc", NA), "'")
sql_quote <- function(x, quote) {
  if (length(x) == 0) {
    return(x)
  }

  y <- gsub(quote, paste0(quote, quote), x, fixed = TRUE)
  y <- paste0(quote, y, quote)
  y[is.na(x)] <- "NULL"
  names(y) <- names(x)

  y
}
