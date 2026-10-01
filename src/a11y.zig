const std = @import("std");
const c = @import("c.zig").c;

// GTK's variadic accessible APIs (gtk_accessible_update_property, ...)
// cannot be emitted by translate-c, so all updates go through the
// non-variadic *_value variants with single-element arrays.

/// Set the accessible label (name) of a widget.
pub fn setLabel(widget: *c.GtkWidget, label: [*:0]const u8) void {
    const string_type = c.g_type_from_name("gchararray");
    if (string_type == 0) return;
    var value: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&value, string_type);
    c.g_value_set_string(&value, label);
    var props = [_]c.GtkAccessibleProperty{c.GTK_ACCESSIBLE_PROPERTY_LABEL};
    var values = [_]c.GValue{value};
    c.gtk_accessible_update_property_value(@ptrCast(widget), 1, &props, &values);
    c.g_value_unset(&value);
}

/// Give a widget the tab role.
pub fn setTabRole(widget: *c.GtkWidget) void {
    var value: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&value, c.gtk_accessible_role_get_type());
    c.g_value_set_enum(&value, c.GTK_ACCESSIBLE_ROLE_TAB);
    c.g_object_set_property(@as(*c.GObject, @ptrCast(widget)), "accessible-role", &value);
    c.g_value_unset(&value);
}

/// Announce selection state to assistive technologies.
pub fn setSelectedState(widget: *c.GtkWidget, selected: bool) void {
    // GtkAccessible expects boolean states as G_TYPE_INT (0/1) here despite
    // the header documenting "boolean"; a G_TYPE_BOOLEAN GValue trips
    // g_value_get_int's type assertion inside GTK.
    const int_type = c.g_type_from_name("gint");
    if (int_type == 0) return;
    var value: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&value, int_type);
    c.g_value_set_int(&value, if (selected) 1 else 0);
    var states = [_]c.GtkAccessibleState{c.GTK_ACCESSIBLE_STATE_SELECTED};
    var values = [_]c.GValue{value};
    c.gtk_accessible_update_state_value(@ptrCast(widget), 1, &states, &values);
    c.g_value_unset(&value);
}

/// Whether GTK animations are enabled (false when the user requested
/// reduced motion). Defaults to enabled when no settings exist.
pub fn animationsEnabled() bool {
    const settings = c.gtk_settings_get_default() orelse return true;
    const bool_type = c.g_type_from_name("gboolean");
    if (bool_type == 0) return true;
    var value: c.GValue = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&value);
    _ = c.g_value_init(&value, bool_type);
    c.g_object_get_property(@as(*c.GObject, @ptrCast(@alignCast(settings))), "gtk-enable-animations", &value);
    return c.g_value_get_boolean(&value) != 0;
}

/// Whether the system high-contrast preference is active.
pub fn highContrast() bool {
    return c.adw_style_manager_get_high_contrast(c.adw_style_manager_get_default()) != 0;
}
