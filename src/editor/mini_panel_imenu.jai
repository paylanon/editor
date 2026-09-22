mini_panel_imenu_procs: Mini_Panel_Procs = {
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

Search_Userdata :: struct {
    original_x: s64; // Not used for listings.
    original_y: s64;
}

Search_Item_Userdata :: struct {
    x: s64;
    y: s64;
}

get_action_text :: (editor: *Editor, platform: Platform, input: Input) -> /* Temporary_Storage */ string {
    return tprint("%  Go to item: ", temp_right_pad(tprint("%", editor.mini_panel.items.count), 4));
}

can_select_text_line :: (editor: *Editor, platform: Platform, input: Input) -> bool {
    return false;
}

init :: (editor: *Editor, platform: Platform, input: Input) {
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

    userdata := arena_push(mini_panel.userdata_arena, Search_Userdata);

    if panel.view.kind == {
        case .DOCUMENT; {
            view := *panel.view._document;
            userdata.original_x = view.cursors.c0.x;
            userdata.original_y = view.cursors.c0.y;
        }
    }

    mini_panel.userdata = userdata;
}

update :: (editor: *Editor, platform: Platform, input: Input, buffer_changed: bool, selected_item_changed: bool) {
    ProfileZone("mini_panel_imenu_update_proc");

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

        array_reset_keeping_memory(*panel.highlights);
        panel.highlight_index = -1;

        search_text := text_buffer_make_view_for_line(mini_panel.buffer, 0,, temp);
        search_parts, smartcase := line_search_prepare_parts(search_text,, temp);
        search_part1_char_count := ifx search_parts.count then count_utf8_chars(search_parts[0]) else 0;

        if panel.view.kind == {
            case .DOCUMENT; {
                view := *panel.view._document;
                document := view.document;

                if document {
                    old_cursor_y   := view.cursors.c0.y;
                    new_item_index := -1;
                    
                    for document.tokens {
                        if !(it.type == .STRUCT_DECLARATION || it.type == .ENUM_DECLARATION || it.type == .PROC_DECLARATION) continue;
                        
                        token := it;
                        token.loc1.x += 1;
                        
                        ident := text_buffer_make_view_for_interval(document.buffer, {token.loc0.x, token.loc0.y}, {token.loc1.x, token.loc1.y});
                        
                        found, found_indices := line_search(ident, search_parts, smartcase,, temp);
                        
                        if found {
                            found_index := found_indices[0]; // TODO(jt): @Incomplete Highlight all found parts.
                            
                            x0 := count_utf8_chars(String.slice(ident, 0, found_index));
                            
                            // highlight := array_add(*panel.highlights);
                            // highlight.x0 = token.loc0.x;
                            // highlight.x1 = token.loc1.x;
                            // highlight.y  = token.loc1.y;
                            
                            item_index := mini_panel.items.count;
                            item := array_add(*mini_panel.items);
                            
                            // NOTE(payl): We could annotate with line number and declaration
                            // type, but I figured text color can get that across without the
                            // need for string alloc.
                            
                            item.text = ident;
                            item.text_color = get_style_for_token_type(editor, it.type);
                            item.highlight_x0 = x0;
                            item.highlight_x1 = x0 + search_part1_char_count;
                            
                            userdata := arena_push(mini_panel.items_arena, Search_Item_Userdata);
                            userdata.x = token.loc0.x;
                            userdata.y = token.loc0.y;
                            
                            item.userdata = userdata;
                            
                            if new_item_index == -1 && token.loc0.y >= old_cursor_y {
                                new_item_index = item_index;
                            }
                        }
                    }
                    
                    if new_item_index == -1 {
                        new_item_index = mini_panel.items.count - 1;
                    }

                    if new_item_index != -1 {
                        mini_panel.item_index = new_item_index;
                        panel.highlight_index = new_item_index;
                        selected_item_changed = true;
                    }
                }
            }
        }
        
        mini_panel.item_index = clamp(mini_panel.item_index, 0, mini_panel.items.count - 1);        
    }
    if selected_item_changed {
        panel.highlight_index = mini_panel.item_index;
        
        // Changing the mini panel buffer OR the selected item can put the index to -1 (in case
        // of search, -1 can only be achieved by changing the buffer), so in general we don't
        // want to assert the index points to the array.
        if mini_panel.item_index >= 0 {
            item := *mini_panel.items[mini_panel.item_index];
            
            userdata: *Search_Item_Userdata = item.userdata;
            x := userdata.x;
            y := userdata.y;
            
            if panel.view.kind == {
                case .DOCUMENT; {
                    view := *panel.view._document;
                    document := view.document;
                    
                    text_buffer_move_to(document.buffer, *view.cursors, x, y, false);
                    
                    view.flags |= .CLAMP_SCROLL_TO_CURSOR;
                    view.flags |= .RECEIVED_INDIRECT_KEYBOARD_INTERACTION;
                }
            }
        }
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
        item := *mini_panel.items[mini_panel.item_index];

        userdata := cast(*Search_Item_Userdata, item.userdata);
        x := userdata.x;
        y := userdata.y;

        if panel.view.kind == {
            case .DOCUMENT; {
                view := *panel.view._document;
                document := view.document;

                if document {
                    text_buffer_move_to(document.buffer, *view.cursors, x, y, false);
                    view.flags |= .CLAMP_SCROLL_TO_CURSOR;
                }
            }

            case .LISTING; {
                view := *panel.view._listing;
                listing := view.listing;

                if listing {
                    view.item_index = clamp(y, 0, listing.items.count - 1);
                    view.flags |= .CLAMP_SCROLL_TO_ITEM_INDEX;
                }
            }
        }
    }

    array_reset_keeping_memory(*panel.highlights);
    panel.highlight_index = -1;

    close_mini_panel(editor, platform, input);

    return false;
}

cancel :: (editor: *Editor, platform: Platform, input: Input) {
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

    userdata: *Search_Userdata = editor.mini_panel.userdata;
    x := userdata.original_x;
    y := userdata.original_y;

    if panel.view.kind == {
        case .DOCUMENT; {
            view := *panel.view._document;
            document := view.document;

            if document {
                text_buffer_move_to(document.buffer, *view.cursors, x, y, view.selecting);
            }

            view.flags |= .CLAMP_SCROLL_TO_CURSOR;
        }

        case .LISTING; {
            view := *panel.view._listing;
            listing := view.listing;

            if listing {
                view.item_index = clamp(y, 0, listing.items.count);
            }

            view.flags |= .CLAMP_SCROLL_TO_ITEM_INDEX;
        }
    }

    array_reset_keeping_memory(*panel.highlights);
    panel.highlight_index = -1;

    close_mini_panel(editor, platform, input);
}
