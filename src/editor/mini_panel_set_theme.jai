mini_panel_set_theme_procs: Mini_Panel_Procs = {
    get_action_text,
    can_select_text_line,
    init,
    update,
    delete_backward,
    autocomplete,
    confirm,
    cancel,
};

#scope_file

BUILTIN_THEME_NAMES  :: #run enum_names(Builtin_Themes);

// NOTE(payl): Only one set of mini-panel procs can be active at
// a time, so we might as well just put stuff in file scope here.

// Set_Theme_Userdata :: struct { original_theme_index: s64; }

original_theme_index: s64;
original_item_index:  s64;

Set_Theme_Item_Userdata :: struct { theme_index: s64; }

get_action_text :: (editor: *Editor, platform: Platform, input: Input) -> /* Temporary_Storage */ string {
    return tprint("%  Set theme: ", temp_right_pad(tprint("%", BUILTIN_THEME_NAMES.count), 4));
}

can_select_text_line :: (editor: *Editor, platform: Platform, input: Input) -> bool {
    return false;
}

init :: (editor: *Editor, platform: Platform, input: Input) {
    original_theme_index = xx editor.theme.builtin_index;
}

update :: (editor: *Editor, platform: Platform, input: Input, buffer_changed: bool, selected_item_changed: bool) {
    mini_panel := *editor.mini_panel;
    sanity_assert(mini_panel.open);
    if !mini_panel.open {
        return;
    }

    if buffer_changed {
        array_reset(*mini_panel.items);
        arena_reset(mini_panel.items_arena);

        search_text := text_buffer_make_view_for_line(mini_panel.buffer, 0,, temp);
        search_parts, smartcase := line_search_prepare_parts(search_text,, temp);
        search_part1_char_count := ifx search_parts.count then count_utf8_chars(search_parts[0]) else 0;
        
        change_theme(editor, BUILTIN_THEME_NAMES[original_theme_index]);
        
        for theme_name: BUILTIN_THEME_NAMES {

            // make original theme sticky
            if it_index == original_theme_index {
                
                mini_panel.item_index = mini_panel.items.count;
                original_item_index = mini_panel.item_index;
                
                item := array_add(*mini_panel.items);
                item.text = arena_push_string(mini_panel.items_arena, tprint("* %", BUILTIN_THEME_NAMES[original_theme_index]));
                
                continue;
            }

            found, found_indices := line_search(theme_name, search_parts, smartcase,, temp);
            if found {
                found_index := found_indices[0]; // TODO(jt): @Incomplete Highlight all found parts.
            
                x0 := count_utf8_chars(String.slice(theme_name, 0, found_index));
                
                item := array_add(*mini_panel.items);
                item.text = theme_name;
                item.highlight_x0 = x0;
                item.highlight_x1 = x0 + search_part1_char_count;

                userdata := arena_push(mini_panel.items_arena, Set_Theme_Item_Userdata);
                userdata.theme_index = it_index;
                item.userdata = userdata;
            }
        }

        mini_panel.item_index = clamp(mini_panel.item_index, 0, mini_panel.items.count - 1);
    }

    if selected_item_changed {
        if mini_panel.item_index == original_item_index {
            change_theme(editor, BUILTIN_THEME_NAMES[original_theme_index]);
        } else {
            item := *mini_panel.items[mini_panel.item_index];
            userdata: *Set_Theme_Item_Userdata = item.userdata;
            change_theme(editor, BUILTIN_THEME_NAMES[userdata.theme_index]);
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

    close_mini_panel(editor, platform, input);
    return false;
}

cancel :: (editor: *Editor, platform: Platform, input: Input) {

    change_theme(editor, BUILTIN_THEME_NAMES[original_theme_index]);
    
    close_mini_panel(editor, platform, input);
}
