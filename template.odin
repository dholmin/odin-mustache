package mustache

import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:runtime"
import "core:slice"
import "core:strings"

/*
  Special characters that will receive HTML-escaping
  treatment, if necessary.
*/
HTML_LESS_THAN :: "&lt;"
HTML_GREATER_THAN :: "&gt;"
HTML_QUOTE :: "&quot;"
HTML_AMPERSAND :: "&amp;"

Data_Error :: enum {
	None,
	Unsupported_Type,
}

Error :: union {
	Data_Error,
}

RenderError :: union {
  LexerError
}

LexerError :: union {
  UnbalancedTags
}

UnbalancedTags :: struct {}

Template :: struct {
  lexer: Lexer,
  data: any,
  partials: any,
  context_stack: [dynamic]ContextStackEntry
}

ContextStackEntry :: struct {
  data: any,
  label: string
}

Data_Type :: enum {
  Map,
  Struct,
  List,
  Value,
  Nil
}

escape_html_string :: proc(s: string, allocator := context.allocator) -> (string) {
  context.allocator = allocator

  escaped := s
  // Ampersand escaping goes first.
  escaped, _ = strings.replace_all(escaped, "&", HTML_AMPERSAND)
  escaped, _ = strings.replace_all(escaped, "<", HTML_LESS_THAN)
  escaped, _ = strings.replace_all(escaped, ">", HTML_GREATER_THAN)
  escaped, _ = strings.replace_all(escaped, "\"", HTML_QUOTE)
  return escaped
}

dig :: proc(d: any, keys: []string) -> any {
  d := d

  if len(keys) == 0 {
    return d
  }

  for key in keys {
    switch data_type(d) {
    case .Struct:
      d = struct_get(d, key)
    case .Map:
      d, _ = map_get(d, key)
    case .List:
      d = d
    case .Value:
      if key == "." {
        d = fmt.aprintf("%v", d) 
      } else {
        return nil
      }
    case .Nil:
      return nil
    case:
      return nil
    }
  }

  return d
}

// TODO: Add a check and throw an error if NOT a struct?
struct_get :: proc(obj: any, key: string) -> any {
  if !is_struct(obj) {
    return nil
  }

  obj := obj
  if is_union(obj) {
    obj = reflect.get_union_variant(obj)
  }

  return reflect.struct_field_value_by_name(obj, key)
}

// Retrieves a value from a map. In mustache.odin, all map keys must be
// string values because we do not know the type of value inside a tag.
//
// Eg., {{name}} -- we assume "name" is either a string key to a map,
// or the name of a field on a struct.
map_get :: proc(v: any, map_key: string) -> (dug: any, err: Error) {
  if !is_map(v) {
    return nil, .Unsupported_Type
  }

  m := (^mem.Raw_Map)(v.data)
  if m == nil {
    return nil, .Unsupported_Type
  }

  v := v
  if is_union(v) {
    v = reflect.get_union_variant(v)
  }

  // Use type_info_base to ensure we get the underlying data structure
  // of a named type if we run into one. Like Map, List, etc.
  base_tinfo := runtime.type_info_base(type_info_of(v.id))
  tinfo := base_tinfo.variant.(runtime.Type_Info_Map)
  map_info := tinfo.map_info

  if map_info == nil {
    return nil, .Unsupported_Type
  }

  map_cap := uintptr(runtime.map_cap(m^))
  ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(m^, map_info)

  for bucket_index in 0..<map_cap {
    runtime.map_hash_is_valid(hs[bucket_index]) or_continue

    // Accessing string type in key
    key_ptr := rawptr(runtime.map_cell_index_dynamic(ks, map_info.ks, bucket_index))
    key_any := any{key_ptr, tinfo.key.id}
    key_info := runtime.type_info_base(type_info_of(key_any.id))
    key_info_any := any{key_any.data, key_info.id}
    key: string

    // Validate that the map keys must be of a string or cstring type.
    #partial switch tinfo in key_info.variant {
    case runtime.Type_Info_String:
      switch s in key_info_any {
      case string: key = s
      case cstring: key = string(s)
      }
    case: return nil, .Unsupported_Type
    }

    // Access the value.
    value_ptr := rawptr(runtime.map_cell_index_dynamic(vs, map_info.vs, bucket_index))
    value_any := any{value_ptr, tinfo.value.id}
    value_info := runtime.type_info_base(type_info_of(value_any.id))
    value_info_any := any{value_any.data, value_info.id}
    value := value_info_any

    // TODO: Do we need to type check the value? I don't think so.
    // #partial switch tinfo in value_info.variant {
    // case runtime.Type_Info_String:
    //   switch s in value_info_any {
    //   case string: value = s
    //   case cstring: value = string(s)
    //   }
    //   fmt.println("string value", value)
    // case runtime.Type_Info_Slice:
    //   fmt.println("slice value", v)
    // case runtime.Type_Info_Dynamic_Array:
    //   fmt.println("dynamic_array value", v)
    // case: return nil, .Unsupported_Type
    // }

    if map_key == key {
      return value, nil
    }
  }

  return nil, nil
}

is_struct :: proc(obj: any) -> bool {
  tid: typeid
  tinfo: ^runtime.Type_Info

  if is_union(obj) {
    tid = reflect.union_variant_typeid(obj)
  } else {
    tid = obj.id
  }

  tinfo = type_info_of(tid)
  return reflect.is_struct(tinfo)
}

is_union :: proc(obj: any) -> bool {
  tinfo: ^runtime.Type_Info
  base_tinfo: ^runtime.Type_Info

  tinfo = type_info_of(obj.id)
  base_tinfo = runtime.type_info_base(tinfo)
  return reflect.type_kind(base_tinfo.id) == reflect.Type_Kind.Union
}

is_map :: proc(obj: any) -> bool {
  tinfo: ^runtime.Type_Info
  id: typeid

  if is_union(obj) {
    id = reflect.union_variant_typeid(obj)
  } else {
    id = obj.id
  }

  tinfo = type_info_of(id)
  return reflect.is_dynamic_map(tinfo)
}

is_list :: proc(obj: any) -> bool {
  tinfo: ^runtime.Type_Info
  id: typeid

  if is_union(obj) {
    id = reflect.union_variant_typeid(obj)
  } else {
    id = obj.id
  }

  tinfo = type_info_of(id)
  return reflect.is_array(tinfo) ||
         reflect.is_enumerated_array(tinfo) ||
         reflect.is_dynamic_array(tinfo) ||
         reflect.is_slice(tinfo)
}

// Checks if a string is plain whitespace.
is_text_blank :: proc(s: string) -> (res: bool) {
  for r in s {
    if !_whitespace[r] {
      return false
    }
  }

  return true
}

/*
  Returns true if the value is one of the "falsey" values
  for a context.
*/
@(private) _falsey_context := map[string]bool{
  "false" = true,
  "null" = true,
  "" = true
}

/*
  Returns true if the value is one of the "falsey" values
  for a context.
*/
@(private) _whitespace := map[rune]bool{
  ' ' = true,
  '\t' = true,
  '\r' = true
}

/*
  Sections can have false-y values in their corresponding data. When this
  is the case, the section should not be rendered. Example:

  input := "\"{{#boolean}}This should not be rendered.{{/boolean}}\""
  data := Map {
    "boolean" = "false"
  }

  Valid contexts are:
    - Map with at least one key
    - List with at least one element
    - string NOT in the _falsey_context mapping
*/
token_valid_in_template_context :: proc(tmpl: ^Template, token: Token) -> (bool) {
  stack_entry := tmpl.context_stack[0]

  // The root stack is always valid.
  if stack_entry.label == "ROOT" {
    return true
  }

  switch data_type(stack_entry.data) {
  case .Map, .List, .Struct:
    return data_len(stack_entry.data) > 0
  case .Value:
    s := fmt.aprintf("%v", stack_entry.data)
    return !_falsey_context[s]
  case .Nil:
    return false
  }

  return false
}

/*
  TODO: Update return value to (string, bool) and add an appropriate
        error and message during the string confirmation phase.
*/
string_for_template_insertion :: proc(tmpl: ^Template, token: Token) -> (string) {
  str: string
  resolved: any
  ok: bool

  if token.value == "." {
    resolved = tmpl.context_stack[0].data
  } else {
    // If the top of the stack is a string and we need to access a hash of data,
    // dig from the layer beneath the top.
    ids := strings.split(token.value, ".", allocator=context.temp_allocator)
    for ctx in tmpl.context_stack {
      resolved = dig(ctx.data, ids[0:1])
      if resolved != nil {
        break
      }
    }

    // Apply "dotted name resolution" if we have parts after the core ID.
    if len(ids[1:]) > 0 {
      last := slice.last(ids[:])
      last_slice := ids[len(ids)-1:]
      resolved = dig(resolved, ids[1:])
      if is_map(resolved) || is_struct(resolved) && has_key(resolved, last) {
        resolved = dig(resolved, last_slice)
      }
    }
  }


  s: string
  switch data_type(resolved) {
  case .Struct, .Map, .List:
    fmt.println("Could not resolve", resolved, "to a value.")
    s = ""
  case .Value:
    s = fmt.aprintf("%v", resolved)
  case .Nil:
    s = ""
  }

  return s
}

template_print_stack :: proc(tmpl: ^Template) {
  fmt.println("Current stack")
  for c, i in tmpl.context_stack {
    fmt.printf("\t[%v] %v: %v\n", i, c.label, c.data)
  }
}

get_data_for_stack :: proc(tmpl: ^Template, data_id: string) -> (data: any) {
  ids := strings.split(data_id, ".")
  defer delete(ids)

  // New stack entries always need to resolve against the current top
  // of the stack entry.
  data = dig(tmpl.context_stack[0].data, ids)

  // If we couldn't resolve against the top of the stack, add from the root.
  if data == nil {
    root_stack_entry := tmpl.context_stack[len(tmpl.context_stack)-1]
    data = dig(root_stack_entry.data, ids)
  }

  // If we still can't find anything, mark this section as false-y.
  if reflect.is_nil(data) {
    return runtime.new_clone("false")^
  } else {
    return data
  }
}

template_add_to_context_stack :: proc(tmpl: ^Template, t: Token, offset: int) {
  data_id := t.value
  data := get_data_for_stack(tmpl, data_id)

  if t.type == .SectionOpenInverted {
    stack_entry := ContextStackEntry{
      data=invert_data(data),
      label=data_id
    }
    inject_at(&tmpl.context_stack, 0, stack_entry)
  } else {
    switch data_type(data) {
    case .Map, .Struct, .Value:
      stack_entry := ContextStackEntry{data=data, label=data_id}
      inject_at(&tmpl.context_stack, 0, stack_entry)
    case .List:
      inject_list_data_into_context_stack(tmpl, data, offset)
    case .Nil:
      stack_entry := ContextStackEntry{data=nil, label=data_id}
      inject_at(&tmpl.context_stack, 0, stack_entry)
    }
  }
}

inject_list_data_into_context_stack :: proc(tmpl: ^Template, list: any, offset: int) {
  section_open := tmpl.lexer.tokens[offset]
  section_name := section_open.value
  start_chunk := offset + 1
  end_chunk := template_find_section_close_tag_index(tmpl, section_name, offset)

  // Remove the original chunk from the token list if the list is empty.
  // We treat empty lists as false-y values.
  if data_len(list) == 0 {
    for _ in start_chunk..<end_chunk {
      ordered_remove(&tmpl.lexer.tokens, start_chunk)
    }
    return
  }

  // If we have a list with contents, update the closing tag with:
  // 1. The number of iterations to perform
  // 2. The position of the start of the loop (eg., .SectionOpen tag)
  section_close := tmpl.lexer.tokens[end_chunk]
  section_close.iters = data_len(list) - 1
  section_close.start_i = offset
  tmpl.lexer.tokens[end_chunk] = section_close

  // Add each element of the list to the context stack. Add the data in
  // reverse order of the list, so that the first entry is at the top.
  for i := section_close.iters; i >= 0; i -= 1 {
    el := list_at(list, i)
    stack_entry := ContextStackEntry{data=el, label="TEMP LIST"}
    inject_at(&tmpl.context_stack, 0, stack_entry)
  }
}

list_at :: proc(obj: any, i: int) -> any {
  obj := obj
  el: any

  if is_union(obj) {
    obj = reflect.get_union_variant(obj)
  }

  if !is_list(obj) {
    return nil
  }

	// type_info := type_info_of(obj.id)
  type_info := runtime.type_info_base(type_info_of(obj.id))
  #partial switch info in type_info.variant {
	case runtime.Type_Info_Array:
    return reflect.index(obj, i)
	case runtime.Type_Info_Slice:
    return reflect.index(obj, i)
	case runtime.Type_Info_Dynamic_Array:
    return reflect.index(obj, i)
  }

  return el
}

data_len :: proc(obj: any) -> int {
  obj := obj
  l: int

  if is_union(obj) {
    obj = reflect.get_union_variant(obj)
  }

  switch data_type(obj) {
  case .Struct:
    l = len(reflect.struct_field_names(obj.id))
  case .Map, .List, .Value:
    l = reflect.length(obj)
  case .Nil:
    l = 0
  }

  return l
}

map_has_key :: proc(v: any, map_key: string) -> (has: bool) {
  if !is_map(v) {
    return false
  }

  m := (^mem.Raw_Map)(v.data)
  if m == nil {
    return false
  }

  v := v
  if is_union(v) {
    v = reflect.get_union_variant(v)
  }

  // Use type_info_base to ensure we get the underlying data structure
  // of a named type if we run into one. Like Map, List, etc.
  base_tinfo := runtime.type_info_base(type_info_of(v.id))
  tinfo := base_tinfo.variant.(runtime.Type_Info_Map)
  map_info := tinfo.map_info

  if map_info == nil {
    return false
  }

  map_cap := uintptr(runtime.map_cap(m^))
  ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(m^, map_info)

  for bucket_index in 0..<map_cap {
    runtime.map_hash_is_valid(hs[bucket_index]) or_continue

    // Accessing string type in key
    key_ptr := rawptr(runtime.map_cell_index_dynamic(ks, map_info.ks, bucket_index))
    key_any := any{key_ptr, tinfo.key.id}
    key_info := runtime.type_info_base(type_info_of(key_any.id))
    key_info_any := any{key_any.data, key_info.id}
    key: string

    // Validate that the map keys must be of a string or cstring type.
    #partial switch tinfo in key_info.variant {
    case runtime.Type_Info_String:
      switch s in key_info_any {
      case string: key = s
      case cstring: key = string(s)
      }
    case: return false
    }

    if map_key == key {
      return true
    }
  }

  return false
}

has_key :: proc(obj: any, key: string) -> (has: bool) {
  obj := obj

  switch data_type(obj) {
  case .Map:
    return map_has_key(obj, key)
  case .Struct:
    if is_union(obj) {
      obj = reflect.get_union_variant(obj)
    }
    fields := reflect.struct_field_names(obj.id)
    return slice.contains(fields, key)
  case .List, .Value, .Nil:
    return false
  }

  return has
}

data_type :: proc(obj: any) -> Data_Type {
  if reflect.is_nil(obj) {
    return .Nil
  } else if is_struct(obj) {
    return .Struct
  } else if is_map(obj) {
    return .Map
  } else if is_list(obj) {
    return .List
  } else {
    return .Value
  }
}

invert_data :: proc(data: any) -> (inverted: any) {
  switch data_type(data) {
  case .Struct, .Map, .List:
    if data_len(data) > 0 {
      return runtime.new_clone("false")^
    } else {
      return runtime.new_clone("true")^
    }
  case .Value:
    s := fmt.aprintf("%v", data)
    if _falsey_context[s] {
      return runtime.new_clone("true")^
    } else {
      return runtime.new_clone("false")^
    }
  case .Nil:
    return runtime.new_clone("true")^
  }

  return runtime.new_clone("false")^
}

// Finds the closing tag with a given value after
// the given offset.
template_find_section_close_tag_index :: proc(
  tmpl: ^Template,
  label: string,
  offset: int
) -> (int) {
  for t, i in tmpl.lexer.tokens[offset:] {
    if t.type == .SectionClose && t.value == label {
      return i + offset
    }
  }

  return -1
}

template_pop_from_context_stack :: proc(tmpl: ^Template) {
  if len(tmpl.context_stack) > 1 {
    ordered_remove(&tmpl.context_stack, 0)
  }
}

token_content :: proc(tmpl: ^Template, t: Token) -> (s: string) {
  switch t.type {
  case .Text:
    // NOTE: Carriage returns causing some wonkiness with .concatenate.
    if t.value != "\r" {
      s = t.value
    }
  case .Tag:
    s = string_for_template_insertion(tmpl, t)
    s = escape_html_string(s)
  case .TagLiteral, .TagLiteralTriple:
    s = string_for_template_insertion(tmpl, t)
  case .Newline:
    s = "\n"
  case .SectionOpen, .SectionOpenInverted, .SectionClose, .Comment, .Skip, .EOF, .Partial:
  }

  return s
}

/*
  When a .Partial token is encountered, we need to inject the contents
  of the partial into the current list of tokens.
*/
template_insert_partial :: proc(
  tmpl: ^Template,
  token: Token,
  offset: int
) -> (err: LexerError) {
  partial_name := token.value
  partial_content := dig(tmpl.partials, []string{partial_name})

  data, ok := partial_content.(string)
  if !ok {
    fmt.println("Could not find partial content.")
    return
  }

  lexer := Lexer{src=data, line=token.pos.line, delim=CORE_DEF}
  parse(&lexer) or_return

  // Performs any indentation on the .Partial that we are inserting.
  //
  // Example: use the first Token as the indentation for the .Partial Token.
  // [Token{type=.Text, value="  "}, Token{type=.Partial, value="to_add"}]
  //
  standalone := is_standalone_partial(tmpl.lexer, token)
  if offset > 0 && standalone {
    prev_token := tmpl.lexer.tokens[offset-1]
    if prev_token.type == .Text && is_text_blank(prev_token.value) {
      cur_line := lexer.tokens[len(lexer.tokens)-1].pos.line
      #reverse for t, i in lexer.tokens {
        // Do not indent the top line.
        if cur_line == 0 {
          break
        }

        // When moving back up a line, insert the indentation.
        if cur_line != t.pos.line {
          inject_at(&lexer.tokens, i+1, prev_token)
        }

        cur_line = t.pos.line
      }
    }
  }

  // Inject tokens from the partial into the primary template.
  #reverse for t in lexer.tokens {
    inject_at(&tmpl.lexer.tokens, offset+1, t)
  }

  return nil
}

template_process :: proc(tmpl: ^Template) -> (output: string, err: RenderError) {
  b: strings.Builder

  root := ContextStackEntry{data=tmpl.data, label="ROOT"}
  inject_at(&tmpl.context_stack, 0, root)

  // First pass to find all the whitespace/newline elements that should be skipped.
  // This is performed up-front due to partial templates -- we cannot check for the
  // whitespace logic *after* the partials have been injected into the template.
  for &t, i in tmpl.lexer.tokens {
    if token_should_skip(tmpl.lexer, t) {
      t.type = .Skip
    }
  }

  // Second pass to render the template.
  i := 0
  for i < len(tmpl.lexer.tokens) {
    defer { i += 1 }
    t := tmpl.lexer.tokens[i]

    // NOTE: For some reason this makes everything work!
    // fmt.println(t)

    switch t.type {
    case .Newline, .Text, .Tag, .TagLiteral, .TagLiteralTriple:
      if token_valid_in_template_context(tmpl, t) {
        strings.write_string(&b, token_content(tmpl, t))
      }
    case .SectionOpen, .SectionOpenInverted:
      template_add_to_context_stack(tmpl, t, i)
    case .SectionClose:
      template_pop_from_context_stack(tmpl)
      if t.iters > 0 {
        t.iters -= 1
        tmpl.lexer.tokens[i] = t
        i = t.start_i
      }
    case .Partial:
      template_insert_partial(tmpl, t, i)
    // Do nothing for these tags.
    case .Comment, .Skip, .EOF:
    }
  }

  return strings.to_string(b), nil
}

render :: proc(
  input: string,
  data: any,
  partials := Map{}
) -> (s: string, err: RenderError) {
  lexer := Lexer{src=input, delim=CORE_DEF}
  defer delete(lexer.tag_stack)
  defer delete(lexer.tokens)

  parse(&lexer) or_return

  template := Template{lexer=lexer, data=data, partials=partials}
  defer delete(template.context_stack)

  text, ok := template_process(&template)
  return text, nil
}

render_from_filename :: proc(
  filename: string,
  data: any
) -> (s: string, err: RenderError) {
  src, _ := os.read_entire_file_from_filename(filename)
  str := string(src)

  lexer := Lexer{src=str, delim=CORE_DEF}
  defer delete(lexer.tag_stack)
  defer delete(lexer.tokens)
  parse(&lexer) or_return

  partials := Map{}
  template := Template{lexer=lexer, data=data, partials=partials}
  defer delete(template.context_stack)

  text, ok := template_process(&template)
  return text, nil
}
