package mustache

import "core:fmt"
import "core:strings"

TokenDelimiter :: struct {
  otag: string,
  ctag: string,
  otag_lit: string,
  ctag_lit: string,
  otag_section_open: string,
  otag_section_close: string,
  otag_literal: string,
  otag_comment: string,
  otag_inverted: string,
  otag_partial: string,
  otag_delim: string,
  ctag_delim: string
}

CORE_DEF :: TokenDelimiter {
  otag = "{{",
  ctag = "}}",
  otag_lit = "{{{",
  ctag_lit = "}}}",
  otag_section_open = "{{#",
  otag_section_close = "{{/",
  otag_literal = "{{&",
  otag_comment = "{{!",
  otag_inverted = "{{^",
  otag_partial = "{{>",
  otag_delim = "{{=",
  ctag_delim = "=}}"
}

Token :: struct {
  type: TokenType,
  value: string,
  pos: Pos,
  iters: int,
  start_i: int
}

TokenType :: enum {
  Text,
  Tag,
  SectionOpenInverted,
  TagLiteral,
  TagLiteralTriple,
  SectionOpen,
  SectionClose,
  Comment,
  Partial,
  Newline,
  Skip,
  EOF // The last token parsed, caller should not call again.
}

Pos :: struct {
  start: int,
  end: int,
  line: int
}

Lexer :: struct {
  src: string,
  cursor: int,
  line: int,
  tokens: [dynamic]Token,
  cur_token_type: TokenType,
  cur_token_start_pos: int,
  tag_stack: [dynamic]rune,
  delim: TokenDelimiter
}

peek :: proc(l: ^Lexer, s: string, offset := 0) -> (bool) {
  peek_i: int
  peeked: rune

  if l.cursor + offset + len(s) >= len(l.src) {
    return false
  }

  for i := 0; i < len(s); i += 1 {
    peek_i = l.cursor + offset + i
    peeked = rune(l.src[peek_i])
    if peeked != rune(s[i]) {
      return false
    }
  }

  return true
}

/*
  Used AFTER a new Token is inserted into the tokens dynamic
  array. In the case of a .TagLiteral ('{{{...}}}'), we need
  to advance the next start position by three instead of two,
  to account for the additional brace.
*/
lexer_start :: proc(l: ^Lexer, new_type: TokenType) {
  cur_type := l.cur_token_type

  switch {
  // Moving from text into a tag.
  case cur_type == .Text:
    switch new_type {
    case .SectionOpen:
      l.cur_token_start_pos = l.cursor + len(l.delim.otag_section_open)
    case .SectionClose:
      l.cur_token_start_pos = l.cursor + len(l.delim.otag_section_close)
    case .SectionOpenInverted:
      l.cur_token_start_pos = l.cursor + len(l.delim.otag_inverted)
    case .Partial:
      l.cur_token_start_pos = l.cursor + len(l.delim.otag_partial)
    case .Comment:
      l.cur_token_start_pos = l.cursor + len(l.delim.otag_comment)
    case .TagLiteral:
      l.cur_token_start_pos = l.cursor + len(l.delim.otag_literal)
    case .TagLiteralTriple:
      l.cur_token_start_pos = l.cursor + len(l.delim.otag_lit)
    case .Tag:
      l.cur_token_start_pos = l.cursor + len(l.delim.otag)
    case .Text, .Newline, .EOF, .Skip:
    }
  // Moving from a tag back into text.
  case new_type == .Text:
    switch cur_type {
    case .Newline:
      l.cur_token_start_pos = l.cursor + len("\n")
    case .Tag, .SectionOpenInverted, .TagLiteral, .SectionClose, .SectionOpen, .Comment, .Partial:
      l.cur_token_start_pos = l.cursor + len(l.delim.ctag)
    case .TagLiteralTriple:
      l.cur_token_start_pos = l.cursor + len(l.delim.ctag_lit)
    case .Text, .EOF, .Skip:
    }
  }

  // Update the current type to the new type.
  l.cur_token_type = new_type
}

/*
  Adds a new token to our list.
*/
lexer_append :: proc(l: ^Lexer) {
  switch l.cur_token_type {
  case .Text:
    append_text(l)
  case .Newline:
    append_newline(l)
  case .Tag, .TagLiteral, .TagLiteralTriple, .Comment, .Partial, .SectionOpen, .SectionOpenInverted, .SectionClose:
    append_tag(l, l.cur_token_type)
  case .EOF, .Skip:
  }
}

append_tag :: proc(l: ^Lexer, token_type: TokenType) {
  pos := Pos{
    start=l.cur_token_start_pos,
    end=l.cursor,
    line=l.line
  }

  if pos.end > pos.start {
    // Remove all empty whitespace inside a valid tag so that we don't
    // mess up our access of the data.
    token_text := l.src[pos.start:pos.end]
    token_text, _ = strings.remove_all(token_text, " ")
    token := Token{type=token_type, value=token_text, pos=pos}
    append(&l.tokens, token)
  }
}

append_text :: proc(l: ^Lexer) {
  pos := Pos{
    start=l.cur_token_start_pos,
    end=l.cursor,
    line=l.line
  }

  if pos.end > pos.start {
    text := l.src[pos.start:pos.end]
    token := Token{type=.Text, value=text, pos=pos}
    append(&l.tokens, token)
  }
}

append_newline :: proc(l: ^Lexer) {
  pos := Pos{
    start=l.cur_token_start_pos,
    end=l.cursor + 1,
    line=l.line
  }

  newline := Token{type=.Newline, value="\n", pos=pos}
  append(&l.tokens, newline)
}

parse :: proc(l: ^Lexer) -> (err: LexerError) {
  for l.cursor < len(l.src) {
    ch := rune(l.src[l.cursor])
    defer { l.cursor += 1 }

    switch {
    // When we hit a newline (and we are not inside a .Comment, as multi-line
    // comments are permitted), add the current chunk as a new Token, insert
    // a special .Newline token, and then begin as a new .Text Token.
    case ch == '\n' && l.cur_token_type != .Comment:
      lexer_append(l)
      lexer_start(l, .Newline)
      lexer_append(l)
      lexer_start(l, .Text)
      l.line += 1
    case peek(l, l.delim.otag_lit):
      lexer_append(l)
      lexer_start(l, .TagLiteralTriple)
    case peek(l, l.delim.otag_section_open):
      lexer_append(l)
      lexer_start(l, .SectionOpen)
    case peek(l, l.delim.otag_section_close):
      lexer_append(l)
      lexer_start(l, .SectionClose)
    case peek(l, l.delim.otag_inverted):
      lexer_append(l)
      lexer_start(l, .SectionOpenInverted)
    case peek(l, l.delim.otag_partial):
      lexer_append(l)
      lexer_start(l, .Partial)
    case peek(l, l.delim.otag_literal):
      lexer_append(l)
      lexer_start(l, .TagLiteral)
    case peek(l, l.delim.otag_comment):
      lexer_append(l)
      lexer_start(l, .Comment)
    // Be careful with checking for "{{" -- it could be a substring of "{{{"
    case peek(l, l.delim.otag) && l.cur_token_type != .TagLiteralTriple:
      lexer_append(l)
      lexer_start(l, .Tag)
    case peek(l, "}") && l.cur_token_type != .Text:
      lexer_append(l)
      lexer_start(l, .Text)
    }
  }

  // Add the last tag and mark that we hit the end of the file.
  lexer_append(l)
  l.cur_token_type = .EOF
  return nil
}

lexer_print_tokens :: proc(l: Lexer) {
  for t, i in l.tokens {
    fmt.println("    ", t)
  }
}

token_should_skip :: proc(l: Lexer, t: Token) -> (skip: bool) {
  switch t.type {
  case .Newline:
    skip = should_skip_newline(l, t)
  case .Text:
    skip = should_skip_text(l, t)
  case .Tag, .TagLiteral, .TagLiteralTriple, .Partial, .SectionOpen, .SectionClose, .SectionOpenInverted:
    skip = false
  case .EOF, .Skip, .Comment:
    skip = true
  }

  return skip
}

// Retrieves all the tokens that are on a given line of the input text.
tokens_on_same_line :: proc(l: Lexer, line: int) -> (tokens: []Token) {
  on_line := false
  start_i: int
  end_i: int

  for t, i in l.tokens {
    if t.pos.line == line && !on_line {
      on_line = true
      start_i = i
    } else if t.pos.line != line && on_line {
      on_line = false
      end_i = i
      break
    }
  }

  if on_line {
    end_i = len(l.tokens)
  }

  if start_i <= end_i {
    return l.tokens[start_i:end_i]
  } else {
    return l.tokens[0:0]
  }
}


// Skip a newline if we are on a line that has either a
// non-blank .Text token OR any valid tags.
should_skip_newline :: proc(l: Lexer, token: Token) -> (bool) {
  on_line := tokens_on_same_line(l, token.pos.line)

  // If the newline is the only token present, do not skip it.
  if len(on_line) == 1 {
    return false
  }

  for t in on_line {
    switch t.type {
    case .Text:
      if !is_text_blank(t.value) {
        return false
      }
    case .Tag, .TagLiteral, .TagLiteralTriple:
      return false
    case .SectionOpen, .SectionClose, .SectionOpenInverted, .Comment,
         .Partial, .Newline, .Skip, .EOF:
    }
  }

  return true
}

// If we are rendering a .Text tag, we should NOT render it if it is:
//  - On a line with one .Section tag, AND
//  - comprised of only whitespace, along with all the other .Text tokens
should_skip_text :: proc(l: Lexer, token: Token) -> (bool) {
  on_line := tokens_on_same_line(l, token.pos.line)

  standalone_tag_count := 0
  for t in on_line {
    switch t.type {
    case .Text:
      if !is_text_blank(t.value) {
        return false
      }
    case .Tag, .TagLiteral, .TagLiteralTriple, .Partial:
      return false
    case .SectionOpen, .SectionOpenInverted, .SectionClose, .Comment:
      standalone_tag_count += 1
    case .Newline, .Skip, .EOF:
    }
  }

  // If we have gotten to the end, that means all the .Text
  // tags on this line are blank. If we also only have a single
  // section or comment tag, that means that tag is standalone.
  return standalone_tag_count == 1
}

/*
  Checks if a given .Partial Token is "standalone."
*/
is_standalone_partial :: proc(l: Lexer, token: Token) -> (bool) {
  on_line := tokens_on_same_line(l, token.pos.line)

  standalone_tag_count := 0
  for t in on_line {
    switch t.type {
    case .Text:
      if !is_text_blank(t.value) {
        return false
      }
    case .Tag, .TagLiteral, .TagLiteralTriple:
      return false
    case .SectionOpen, .SectionOpenInverted, .SectionClose, .Comment, .Partial:
      standalone_tag_count += 1
    case .Newline, .Skip, .EOF:
    }
  }

  // If we have gotten to the end, that means all the .Text
  // tags on this line are blank. If we also only have a single
  // section or comment tag, that means that tag is standalone.
  return standalone_tag_count == 1
}
