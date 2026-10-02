const c = @import("c.zig");

pub extern fn gtk_init_check() c.gboolean;
pub extern fn gtk_get_major_version() c.guint;
pub extern fn gtk_get_minor_version() c.guint;
pub extern fn gtk_get_micro_version() c.guint;
pub extern fn gtk_message_dialog_new(parent: ?*c.GtkWindow, flags: c.GtkDialogFlags, message_type: c.GtkMessageType, buttons: c.GtkButtonsType, message_format: ?[*:0]const u8, ...) *c.GtkWidget;
pub extern fn gtk_message_dialog_format_secondary_markup(dialog: *c.GtkMessageDialog, message_format: ?[*:0]const u8, ...) void;
pub extern fn gtk_dialog_add_button(
    dialog: *c.GtkDialog,
    button_text: [*:0]const u8,
    response_id: c_int,
) *c.GtkWidget;
pub extern fn gtk_application_new(application_id: ?[*:0]const u8, flags: c.GApplicationFlags) *c.GtkApplication;
pub extern fn gtk_application_window_new(application: *c.GtkApplication) *c.GtkWidget;
pub extern fn gtk_window_set_title(window: *c.GtkWindow, title: ?[*:0]const u8) void;
pub extern fn gtk_window_set_decorated(window: *c.GtkWindow, setting: c.gboolean) void;
pub extern fn gtk_window_set_resizable(window: *c.GtkWindow, resizable: c.gboolean) void;
pub extern fn gtk_window_set_default_size(window: *c.GtkWindow, width: c_int, height: c_int) void;
pub extern fn gtk_window_set_child(window: *c.GtkWindow, child: ?*c.GtkWidget) void;
pub extern fn gtk_window_present(window: *c.GtkWindow) void;
pub extern fn gtk_window_destroy(window: *c.GtkWindow) void;
pub extern fn gtk_window_is_active(window: *c.GtkWindow) c.gboolean;
pub extern fn gtk_window_get_focus(window: *c.GtkWindow) ?*c.GtkWidget;
pub extern fn gtk_native_get_surface(self: *c.GtkNative) ?*c.GdkSurface;
pub extern fn gtk_native_get_surface_transform(self: *c.GtkNative, x: *f64, y: *f64) void;
pub extern fn gtk_widget_realize(widget: *c.GtkWidget) void;
pub extern fn gtk_widget_set_overflow(widget: *c.GtkWidget, overflow: c.GtkOverflow) void;
pub extern fn gtk_widget_set_opacity(widget: *c.GtkWidget, opacity: f64) void;
pub extern fn gtk_widget_set_valign(widget: *c.GtkWidget, alignment: c.GtkAlign) void;
pub extern fn gtk_widget_set_hexpand(widget: *c.GtkWidget, expand: c.gboolean) void;
pub extern fn gtk_widget_set_vexpand(widget: *c.GtkWidget, expand: c.gboolean) void;
pub extern fn gtk_widget_set_size_request(widget: *c.GtkWidget, width: c_int, height: c_int) void;
pub extern fn gtk_widget_set_can_focus(widget: *c.GtkWidget, can_focus: c.gboolean) void;
pub extern fn gtk_widget_set_can_target(widget: *c.GtkWidget, can_target: c.gboolean) void;
pub extern fn gtk_widget_grab_focus(widget: *c.GtkWidget) c.gboolean;
pub extern fn gtk_widget_add_css_class(widget: *c.GtkWidget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_add_controller(widget: *c.GtkWidget, controller: *c.GtkEventController) void;
pub extern fn gtk_widget_get_first_child(widget: *c.GtkWidget) ?*c.GtkWidget;
pub extern fn gtk_widget_is_ancestor(widget: *c.GtkWidget, ancestor: *c.GtkWidget) c.gboolean;
pub extern fn gtk_widget_get_clipboard(widget: *c.GtkWidget) *c.GdkClipboard;
pub extern fn gtk_widget_set_margin_start(widget: *c.GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_end(widget: *c.GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_top(widget: *c.GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(widget: *c.GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_measure(
    widget: *c.GtkWidget,
    orientation: c.GtkOrientation,
    for_size: c_int,
    minimum: ?*c_int,
    natural: ?*c_int,
    minimum_baseline: ?*c_int,
    natural_baseline: ?*c_int,
) void;
pub extern fn gtk_widget_compute_bounds(
    widget: *c.GtkWidget,
    target: *c.GtkWidget,
    out_bounds: *c.graphene_rect_t,
) c.gboolean;
pub extern fn gtk_box_new(orientation: c.GtkOrientation, spacing: c_int) *c.GtkWidget;
pub extern fn gtk_box_append(box: *c.GtkBox, child: *c.GtkWidget) void;
pub extern fn gtk_box_remove(box: *c.GtkBox, child: *c.GtkWidget) void;
pub extern fn gtk_box_reorder_child_after(box: *c.GtkBox, child: *c.GtkWidget, sibling: ?*c.GtkWidget) void;
pub extern fn gtk_overlay_new() *c.GtkWidget;
pub extern fn gtk_overlay_add_overlay(overlay: *c.GtkOverlay, widget: *c.GtkWidget) void;
pub extern fn gtk_overlay_set_measure_overlay(
    overlay: *c.GtkOverlay,
    widget: *c.GtkWidget,
    measure: c.gboolean,
) void;
pub extern fn gtk_separator_new(orientation: c.GtkOrientation) *c.GtkWidget;
pub extern fn gtk_button_new_with_label(label: [*:0]const u8) *c.GtkWidget;
pub extern fn gtk_button_set_has_frame(button: *c.GtkButton, has_frame: c.gboolean) void;
pub extern fn gtk_label_new(str: ?[*:0]const u8) *c.GtkWidget;
pub extern fn gtk_label_get_text(self: *c.GtkLabel) [*:0]const u8;
pub extern fn gtk_label_set_text(self: *c.GtkLabel, str: [*:0]const u8) void;
pub extern fn gtk_label_set_markup(self: *c.GtkLabel, str: [*:0]const u8) void;
pub extern fn gtk_label_set_ellipsize(self: *c.GtkLabel, mode: c.PangoEllipsizeMode) void;
pub extern fn gtk_label_set_max_width_chars(self: *c.GtkLabel, n_chars: c_int) void;
pub extern fn gtk_label_set_xalign(self: *c.GtkLabel, xalign: f32) void;
pub extern fn gtk_image_new() *c.GtkWidget;
pub extern fn gtk_image_set_from_gicon(image: *c.GtkImage, icon: ?*c.GIcon) void;
pub extern fn gtk_image_set_from_icon_name(image: *c.GtkImage, icon_name: ?[*:0]const u8) void;
pub extern fn gtk_image_set_pixel_size(image: *c.GtkImage, pixel_size: c_int) void;
pub extern fn gtk_entry_new() *c.GtkWidget;
pub extern fn gtk_entry_get_buffer(entry: *c.GtkEntry) *c.GtkEntryBuffer;
pub extern fn gtk_entry_set_placeholder_text(entry: *c.GtkEntry, text: ?[*:0]const u8) void;
pub extern fn gtk_entry_set_icon_from_gicon(
    entry: *c.GtkEntry,
    icon_pos: c.GtkEntryIconPosition,
    icon: ?*c.GIcon,
) void;
pub extern fn gtk_entry_grab_focus_without_selecting(entry: *c.GtkEntry) c.gboolean;
pub extern fn gtk_entry_buffer_get_text(buffer: *c.GtkEntryBuffer) [*:0]const u8;
pub extern fn gtk_entry_buffer_set_text(buffer: *c.GtkEntryBuffer, chars: [*:0]const u8, n_chars: c_int) void;
pub extern fn gtk_editable_select_region(editable: *c.GtkEditable, start_pos: c_int, end_pos: c_int) void;
pub extern fn gtk_list_box_new() *c.GtkWidget;
pub extern fn gtk_list_box_append(box: *c.GtkListBox, child: *c.GtkWidget) void;
pub extern fn gtk_list_box_remove(box: *c.GtkListBox, child: *c.GtkWidget) void;
pub extern fn gtk_list_box_set_selection_mode(box: *c.GtkListBox, mode: c.GtkSelectionMode) void;
pub extern fn gtk_list_box_select_row(box: *c.GtkListBox, row: ?*c.GtkListBoxRow) void;
pub extern fn gtk_list_box_get_selected_row(box: *c.GtkListBox) ?*c.GtkListBoxRow;
pub extern fn gtk_list_box_get_row_at_index(box: *c.GtkListBox, index: c_int) ?*c.GtkListBoxRow;
pub extern fn gtk_list_box_row_get_index(row: *c.GtkListBoxRow) c_int;
pub extern fn gtk_scrolled_window_new() *c.GtkWidget;
pub extern fn gtk_scrolled_window_set_child(window: *c.GtkScrolledWindow, child: ?*c.GtkWidget) void;
pub extern fn gtk_scrolled_window_set_policy(
    window: *c.GtkScrolledWindow,
    hscrollbar_policy: c.GtkPolicyType,
    vscrollbar_policy: c.GtkPolicyType,
) void;
pub extern fn gtk_scrolled_window_set_propagate_natural_height(
    window: *c.GtkScrolledWindow,
    propagate: c.gboolean,
) void;
pub extern fn gtk_scrolled_window_set_max_content_height(window: *c.GtkScrolledWindow, height: c_int) void;
pub extern fn gtk_scrolled_window_get_vadjustment(window: *c.GtkScrolledWindow) *c.GtkAdjustment;
pub extern fn gtk_adjustment_get_value(adjustment: *c.GtkAdjustment) c.gdouble;
pub extern fn gtk_adjustment_set_value(adjustment: *c.GtkAdjustment, value: c.gdouble) void;
pub extern fn gtk_adjustment_get_page_size(adjustment: *c.GtkAdjustment) c.gdouble;
pub extern fn gtk_css_provider_new() *c.GtkCssProvider;
pub extern fn gtk_css_provider_load_from_string(provider: *c.GtkCssProvider, string: [*:0]const u8) void;
pub extern fn gtk_style_context_add_provider_for_display(
    display: *c.GdkDisplay,
    provider: *c.GtkStyleProvider,
    priority: c.guint,
) void;
pub extern fn gtk_notebook_new() *c.GtkWidget;
pub extern fn gtk_notebook_append_page(
    notebook: *c.GtkNotebook,
    child: *c.GtkWidget,
    tab_label: ?*c.GtkWidget,
) c_int;
pub extern fn gtk_notebook_remove_page(notebook: *c.GtkNotebook, page_num: c_int) void;
pub extern fn gtk_notebook_get_n_pages(notebook: *c.GtkNotebook) c_int;
pub extern fn gtk_notebook_set_current_page(notebook: *c.GtkNotebook, page_num: c_int) void;
pub extern fn gtk_notebook_get_current_page(notebook: *c.GtkNotebook) c_int;
pub extern fn gtk_notebook_get_nth_page(notebook: *c.GtkNotebook, page_num: c_int) ?*c.GtkWidget;
pub extern fn gtk_notebook_get_tab_label_text(
    notebook: *c.GtkNotebook,
    child: *c.GtkWidget,
) ?[*:0]const u8;
pub extern fn gtk_notebook_set_scrollable(notebook: *c.GtkNotebook, scrollable: c.gboolean) void;
pub extern fn gtk_text_view_new() *c.GtkWidget;
pub extern fn gtk_text_view_get_buffer(view: *c.GtkTextView) *c.GtkTextBuffer;
pub extern fn gtk_text_view_set_editable(view: *c.GtkTextView, setting: c.gboolean) void;
pub extern fn gtk_text_view_set_cursor_visible(view: *c.GtkTextView, setting: c.gboolean) void;
pub extern fn gtk_text_view_set_monospace(view: *c.GtkTextView, monospace: c.gboolean) void;
pub extern fn gtk_text_view_set_wrap_mode(view: *c.GtkTextView, wrap_mode: c.GtkWrapMode) void;
pub extern fn gtk_text_view_set_bottom_margin(view: *c.GtkTextView, margin: c_int) void;
pub extern fn gtk_text_buffer_set_text(buffer: *c.GtkTextBuffer, text: [*:0]const u8, len: c_int) void;
pub extern fn gtk_text_buffer_get_end_iter(buffer: *c.GtkTextBuffer, iter: *c.GtkTextIter) void;
pub extern fn gtk_text_buffer_create_mark(
    buffer: *c.GtkTextBuffer,
    mark_name: ?[*:0]const u8,
    where: *const c.GtkTextIter,
    left_gravity: c.gboolean,
) *c.GtkTextMark;
pub extern fn gtk_text_buffer_delete_mark(buffer: *c.GtkTextBuffer, mark: *c.GtkTextMark) void;
pub extern fn gtk_text_view_scroll_to_mark(
    view: *c.GtkTextView,
    mark: *c.GtkTextMark,
    within_margin: c.gdouble,
    use_align: c.gboolean,
    xalign: c.gdouble,
    yalign: c.gdouble,
) void;
pub extern fn gtk_text_buffer_insert(
    buffer: *c.GtkTextBuffer,
    iter: *c.GtkTextIter,
    text: [*]const u8,
    len: c_int,
) void;
pub extern fn gtk_widget_set_visible(widget: *c.GtkWidget, visible: c.gboolean) void;
pub extern fn gtk_widget_get_visible(widget: *c.GtkWidget) c.gboolean;
pub extern fn gtk_event_controller_key_new() *c.GtkEventController;
pub extern fn gtk_event_controller_set_propagation_phase(
    controller: *c.GtkEventController,
    phase: c.GtkPropagationPhase,
) void;
pub extern fn gtk_event_controller_focus_new() *c.GtkEventController;
pub extern fn gtk_picture_new() *c.GtkWidget;
pub extern fn gtk_picture_set_paintable(self: *c.GtkPicture, paintable: ?*c.GdkPaintable) void;
pub extern fn gtk_picture_set_content_fit(self: *c.GtkPicture, content_fit: c.GtkContentFit) void;
pub extern fn gtk_picture_set_can_shrink(self: *c.GtkPicture, can_shrink: c.gboolean) void;
pub extern fn gtk_media_file_new_for_input_stream(stream: *c.GInputStream) *c.GtkMediaFile;
pub extern fn gtk_media_stream_set_loop(self: *c.GtkMediaStream, loop: c.gboolean) void;
pub extern fn gtk_media_stream_play(self: *c.GtkMediaStream) void;
pub extern fn gtk_media_stream_pause(self: *c.GtkMediaStream) void;
pub extern fn gtk_media_file_clear(self: *c.GtkMediaFile) void;
pub extern fn gtk_window_new() *c.GtkWidget;
pub extern fn gtk_widget_set_sensitive(widget: *c.GtkWidget, sensitive: c.gboolean) void;
pub extern fn gtk_drop_down_new_from_strings(strings: [*:null]const ?[*:0]const u8) *c.GtkWidget;
pub extern fn gtk_drop_down_set_selected(self: *c.GtkDropDown, position: c.guint) void;
pub extern fn gtk_drop_down_get_selected(self: *c.GtkDropDown) c.guint;
pub extern fn gtk_adjustment_get_upper(adjustment: *c.GtkAdjustment) c.gdouble;
pub extern fn gtk_widget_set_cursor_from_name(widget: *c.GtkWidget, name: ?[*:0]const u8) void;
pub extern fn gtk_fixed_new() *c.GtkWidget;
pub extern fn gtk_fixed_put(fixed: *c.GtkFixed, widget: *c.GtkWidget, x: c.gdouble, y: c.gdouble) void;
pub extern fn gtk_fixed_move(fixed: *c.GtkFixed, widget: *c.GtkWidget, x: c.gdouble, y: c.gdouble) void;
pub extern fn gtk_gesture_drag_new() *c.GtkGesture;
pub extern fn gtk_gesture_click_new() *c.GtkGesture;
pub extern fn gtk_gesture_single_set_button(gesture: *c.GtkGesture, button: c.guint) void;
pub extern fn gtk_event_controller_motion_new() *c.GtkEventController;
pub extern fn gtk_icon_theme_get_for_display(display: *c.GdkDisplay) *c.GtkIconTheme;
pub extern fn gtk_icon_theme_has_icon(self: *c.GtkIconTheme, icon_name: [*:0]const u8) c.gboolean;
