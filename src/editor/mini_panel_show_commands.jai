mini_panel_show_commands_procs: Mini_Panel_Procs = {
    get_action_text,
    can_select_text_line,
    init,
    update,
    delete_backward,
    autocomplete,
    confirm,
    cancel,
    *history,
    false
};

#scope_file

history: Mini_Panel_History;

PANEL_ACTION_NAMES   :: #run enum_names(Panel_Action);
PANEL_ACTIONS_VALUES :: #run enum_values_as_s64(Panel_Action);

DOCUMENT_ACTION_NAMES  :: #run enum_names(Document_Action);
DOCUMENT_ACTION_VALUES :: #run enum_values_as_s64(Document_Action);

COMPILATION_ACTION_NAMES  :: #run enum_names(Compilation_Action);
COMPILATION_ACTION_VALUES :: #run enum_values_as_s64(Compilation_Action);

LISTING_ACTION_NAMES  :: #run enum_names(Listing_Action);
LISTING_ACTION_VALUES :: #run enum_values_as_s64(Listing_Action);

Action_Kind :: enum { UNINITIALIZED; PANEL; DOCUMENT; DOCUMENT_MACRO; COMPILATION; LISTING; };

Show_Commands_Item_Userdata :: struct {
    kind:  Action_Kind;
    value: s64;
}

get_action_text :: (editor: *Editor, platform: Platform, input: Input) -> /* Temporary_Storage */ string {
    panel := get_panel_for_active_view(editor);
    sanity_assert(panel != null);
    if !panel {
        return tprint("% Commands: ", temp_right_pad(tprint("%", editor.mini_panel.items.count), 4));
    }

    template: string;
    if #complete panel.view.kind == {
        case .DOCUMENT; {
            if panel.view._document.document.kind == .COMPILATION {
                template = "% Commands for *compilation*: ";
            } else {
                template = "% Commands for document: ";
            }
        }

        case .LISTING;  template = "% Commands for directory: ";
    }

    return tprint(template, temp_right_pad(tprint("%", editor.mini_panel.items.count), 4));
}

can_select_text_line :: (editor: *Editor, platform: Platform, input: Input) -> bool {
    return false;
}

init :: (editor: *Editor, platform: Platform, input: Input) {}

update :: (editor: *Editor, platform: Platform, input: Input, buffer_changed: bool, selected_item_changed: bool) {
    mini_panel := *editor.mini_panel;
    sanity_assert(mini_panel.open);
    if !mini_panel.open {
        return;
    }

    panel := get_panel_for_active_view(editor);
    sanity_assert(panel != null);
    if !panel {
        return;
    }

    if buffer_changed {
        array_reset(*mini_panel.items);
        arena_reset(mini_panel.items_arena);

        search_text := text_buffer_make_view_for_line(mini_panel.buffer, 0,, temp);
        search_parts, smartcase := line_search_prepare_parts(search_text,, temp);
        search_part1_char_count := ifx search_parts.count then count_utf8_chars(search_parts[0]) else 0;

        actions_to_search_names: [..] string;
        actions_to_search_names.allocator = temp;

        actions_to_search_values: [..] s64;
        actions_to_search_values.allocator = temp;
        
        array_reserve(*actions_to_search_names, history.elements.count + PANEL_ACTION_NAMES.count);
        array_reserve(*actions_to_search_values, history.elements.count + PANEL_ACTION_NAMES.count);
        
        history_cursor := history.elements.count;
        history_action_kinds := NewArray(history.elements.count, Action_Kind,, temp);
        
        for history.elements {
            array_add(*actions_to_search_names, {});
            array_add(*actions_to_search_values, 0);
        }
        
        // @NOTE(payl): never felt too good about using macros
        // like this, but alas my textbook says DRY
        
        check_history :: (name: string, kind: Action_Kind) -> bool #expand {
            
            if `history_cursor && String.equal_nocase(name, history.elements[`history_cursor-1]) {
                index := history.elements.count - `history_cursor;
                `actions_to_search_names[index] = `action_text;
                `actions_to_search_values[index] = `action;
                history_action_kinds[index] = kind;
                `history_cursor -= 1;
                return true;
            } else return false;
        }
        
        for PANEL_ACTION_NAMES {
            if it != "NONE" {
                
                key_map := *editor.panel_key_map;
                action  := PANEL_ACTIONS_VALUES[it_index];
                action_text := build_action_text(action, it, key_map);
                      
                if check_history(it, .PANEL) continue;
                
                array_add(*actions_to_search_names, action_text);
                array_add(*actions_to_search_values, action);
            }
        }
        assert(actions_to_search_names.count == actions_to_search_values.count);

        panel_actions_low:  s64 = history.elements.count;
        panel_actions_high: s64 = actions_to_search_names.count;

        document_actions_low:  s64 = actions_to_search_names.count;
        document_actions_high: s64 = actions_to_search_names.count;

        document_macros_low:  s64 = actions_to_search_names.count;
        document_macros_high: s64 = actions_to_search_names.count;

        compilation_actions_low:  s64 = actions_to_search_names.count;
        compilation_actions_high: s64 = actions_to_search_names.count;

        listing_actions_low:  s64 = actions_to_search_names.count;
        listing_actions_high: s64 = actions_to_search_names.count;

        if panel.view.kind == {
            case .DOCUMENT; {
                if panel.view._document.document.kind == .COMPILATION {
                    array_reserve(*actions_to_search_names, actions_to_search_names.count + COMPILATION_ACTION_NAMES.count);
                    array_reserve(*actions_to_search_values, actions_to_search_values.count + COMPILATION_ACTION_NAMES.count);
                    for COMPILATION_ACTION_NAMES {
                        if it != "NONE" {
                            key_map := *editor.compilation_key_map;
                            action  := COMPILATION_ACTION_VALUES[it_index];
                            action_text := build_action_text(action, it, key_map);
                            
                            if check_history(it, .COMPILATION) continue;
                            
                            array_add(*actions_to_search_names, action_text);
                            array_add(*actions_to_search_values, action);
                        }
                    }
                    assert(actions_to_search_names.count == actions_to_search_values.count);

                    compilation_actions_high = actions_to_search_names.count;
                } else {
                    array_reserve(*actions_to_search_names, actions_to_search_names.count + DOCUMENT_ACTION_NAMES.count);
                    array_reserve(*actions_to_search_values, actions_to_search_values.count + DOCUMENT_ACTION_NAMES.count);
                    for DOCUMENT_ACTION_NAMES {
                        if it != "NONE" {
                            key_map := *editor.document_key_map;
                            action  := DOCUMENT_ACTION_VALUES[it_index];
                            action_text := build_action_text(action, it, key_map);
                            
                            if check_history(it, .DOCUMENT) continue;
                            
                            array_add(*actions_to_search_names, action_text);
                            array_add(*actions_to_search_values, action);
                        }
                    }
                    assert(actions_to_search_names.count == actions_to_search_values.count);

                    document_actions_high = actions_to_search_names.count;

                    for document_macros {
                        action_text := build_action_text(it);
                        action := it_index;
                        
                        if check_history(it.name, .DOCUMENT_MACRO) continue;
                        
                        array_add(*actions_to_search_names, action_text);
                        array_add(*actions_to_search_values, action);
                    }
                    assert(actions_to_search_names.count == actions_to_search_values.count);

                    document_macros_high = actions_to_search_names.count;
                }
            }
            case .LISTING; {
                array_reserve(*actions_to_search_names, actions_to_search_names.count + LISTING_ACTION_NAMES.count);
                array_reserve(*actions_to_search_values, actions_to_search_values.count + LISTING_ACTION_NAMES.count);
                for LISTING_ACTION_NAMES {
                    if it != "NONE" {
                        key_map := *editor.listing_key_map;
                        action  := LISTING_ACTION_VALUES[it_index];
                        action_text := build_action_text(action, it, key_map);
                        
                        if check_history(it, .LISTING) continue;
                        
                        array_add(*actions_to_search_names, action_text);
                        array_add(*actions_to_search_values, action);
                    }
                }
                assert(actions_to_search_names.count == actions_to_search_values.count);

                listing_actions_high = actions_to_search_names.count;
            }
        }
        
        assert(!history_cursor);
        
        style_ranges := NewArray(2, Font_Style_Range,, arena_allocator(mini_panel.items_arena));
        style_ranges[0].x1 = ACTION_TEXT_PADDING - 1;
        style_ranges[0].color = editor.theme.text_color;
        style_ranges[1].x0 = ACTION_TEXT_PADDING;
        style_ranges[1].x1 = ACTION_TEXT_PADDING * 2;
        style_ranges[1].color = editor.theme.comment_color;

        for actions_to_search_names {
            found, found_indices := line_search(it, search_parts, smartcase,, temp);
            if found {
                found_index := found_indices[0]; // TODO(jt): @Incomplete Highlight all found parts.

                x0 := count_utf8_chars(String.slice(it, 0, found_index));

                s := arena_push_string(mini_panel.items_arena, it);

                item := array_add(*mini_panel.items);
                item.text = s;
                item.text_style_ranges = style_ranges;
                item.highlight_x0 = x0;
                item.highlight_x1 = x0 + search_part1_char_count;

                userdata := arena_push(mini_panel.items_arena, Show_Commands_Item_Userdata);
                userdata.kind = .UNINITIALIZED;
                userdata.value = actions_to_search_values[it_index];

                if it_index < panel_actions_low {
                    userdata.kind = history_action_kinds[it_index];
                } else if it_index >= panel_actions_low && it_index < panel_actions_high {
                    userdata.kind = .PANEL;
                } else if it_index >= document_actions_low && it_index < document_actions_high {
                    userdata.kind = .DOCUMENT;
                } else if it_index >= document_macros_low && it_index < document_macros_high {
                    userdata.kind = .DOCUMENT_MACRO;
                } else if it_index >= compilation_actions_low && it_index < compilation_actions_high {
                    userdata.kind = .COMPILATION;
                } else if it_index >= listing_actions_low && it_index < listing_actions_high {
                    userdata.kind = .LISTING;
                }

                item.userdata = userdata;
            }
        }

        mini_panel.item_index = clamp(mini_panel.item_index, 0, mini_panel.items.count - 1);
    }
}

delete_backward :: (editor: *Editor, platform: Platform, input: Input) -> buffer_changed: bool {
    mini_panel := *editor.mini_panel;
    sanity_assert(mini_panel.open);
    if !mini_panel.open {
        return false;
    }

    gb := mini_panel.buffer.gb;
    if gb.count {
        text_buffer_delete_backward(*mini_panel.buffer, *mini_panel.cursors);
        return true;
    }

    return false;
}

autocomplete :: (editor: *Editor, platform: Platform, input: Input) -> buffer_changed: bool {
    mini_panel := *editor.mini_panel;
    sanity_assert(mini_panel.open);
    if !mini_panel.open {
        return false;
    }

    if mini_panel.items.count == 1 {
        text_buffer_delete_all(*mini_panel.buffer, *mini_panel.cursors);
        text_buffer_insert(*mini_panel.buffer, *mini_panel.cursors, mini_panel.items[0].text);

        return true;
    } else if mini_panel.items.count > 1 {
        text_buffer_delete_all(*mini_panel.buffer, *mini_panel.cursors);
        text_buffer_insert(*mini_panel.buffer, *mini_panel.cursors, mini_panel.items[mini_panel.item_index].text);

        return true;
    }

    return false;
}

confirm :: (editor: *Editor, platform: Platform, input: Input) -> buffer_changed: bool {
    mini_panel := *editor.mini_panel;
    sanity_assert(mini_panel.open);
    if !mini_panel.open {
        return false;
    }

    panel := get_panel_for_active_view(editor);
    sanity_assert(panel != null);
    if !panel {
        return false;
    }

    if mini_panel.items.count {
        assert(mini_panel.item_index >= 0);

        // IMPORTANT! Because actions can open the mini panel, we have to close it before we
        // execute. However, this means we release all arenas etc., so if there is something we
        // need, we need to make a copy now.
        userdata_pointer: *Show_Commands_Item_Userdata = mini_panel.items[mini_panel.item_index].userdata;
        userdata := userdata_pointer.*;

        close_mini_panel(editor, platform, input);

        if #complete userdata.kind == {
            case .UNINITIALIZED;  sanity_assert(false);

            case .PANEL; {
                action := cast(Panel_Action, userdata.value);
                execute_panel_action(editor, platform, input, panel, action);
            }

            case .DOCUMENT; {
                sanity_assert(panel.view.kind == .DOCUMENT);
                view := *panel.view._document;
                document := view.document;

                sanity_assert(document.kind != .COMPILATION);
                action := cast(Document_Action, userdata.value);
                execute_document_action(editor, platform, input, panel, view, document, action);
            }

            case .DOCUMENT_MACRO; {
                sanity_assert(panel.view.kind == .DOCUMENT);
                view := *panel.view._document;
                document := view.document;

                sanity_assert(document.kind != .COMPILATION);
                macro := document_macros[userdata.value];
                execute_document_macro(editor, platform, input, panel, view, document, macro);
            }

            case .COMPILATION; {
                sanity_assert(panel.view.kind == .DOCUMENT);
                view := *panel.view._document;
                document := view.document;

                sanity_assert(document.kind == .COMPILATION);
                action := cast(Compilation_Action, userdata.value);
                execute_compilation_action(editor, platform, input, panel, view, document, action);
            }

            case .LISTING; {
                action := cast(Listing_Action, userdata.value);

                sanity_assert(panel.view.kind == .LISTING);
                view := *panel.view._listing;
                listing := view.listing;

                execute_listing_action(editor, platform, input, panel, view, listing, action);
            }
        }
    } else {
        close_mini_panel(editor, platform, input);
    }

    return false;
}

cancel :: (editor: *Editor, platform: Platform, input: Input) {
    close_mini_panel(editor, platform, input);
}

ACTION_TEXT_PADDING :: 40;
build_action_text :: (action: s64, action_name: string, key_map: Key_Map) -> /* Temporary_Storage */ string {
    sb: String_Builder;
    sb.allocator = temp;

    action_padded := temp_right_pad(action_name, ACTION_TEXT_PADDING);
    String.to_lower_in_place(action_padded);

    append(*sb, action_padded);

    first := true;
    for registered_action, registered_index: key_map.registered_actions {
        if cast(s64, registered_action) == action {
            if !first {
                append(*sb, ", ");
            }
            shortcut_print_to_builder(key_map.registered_shortcuts[registered_index], *sb);
            first = false;
        }
    }

    return builder_to_string(*sb,, temp);
}

build_action_text :: (macro: Document_Macro) -> /* Temporary_Storage */ string {
    sb: String_Builder;
    sb.allocator = temp;

    action_padded := temp_right_pad(macro.name, 40);
    String.to_lower_in_place(action_padded);

    append(*sb, action_padded);

    // TODO(payl) multiple shortcuts
    shortcut_print_to_builder(macro.shortcut, *sb);

    return builder_to_string(*sb,, temp);
}
