const std = @import("std");
const c = @import("c.zig").c;
const Pane = @import("pane.zig").Pane;
const WebPanel = @import("web_panel.zig").WebPanel;

pub const PanelType = enum {
    terminal,
    webkit,
};

pub const Panel = union(PanelType) {
    terminal: *Pane,
    webkit: *WebPanel,

    pub fn getWidget(self: Panel) *c.GtkWidget {
        return switch (self) {
            .terminal => |p| p.widget,
            .webkit => |wp| wp.widget,
        };
    }

    pub fn getId(self: Panel) u64 {
        return switch (self) {
            .terminal => |p| p.id,
            .webkit => |wp| wp.id,
        };
    }

    pub fn focus(self: Panel) void {
        switch (self) {
            .terminal => |p| p.focus(),
            .webkit => |wp| wp.focus(),
        }
    }

    pub fn unfocus(self: Panel) void {
        switch (self) {
            .terminal => |p| p.unfocus(),
            .webkit => |wp| wp.unfocus(),
        }
    }

    pub fn disconnectSignals(self: Panel) void {
        switch (self) {
            .terminal => |p| p.disconnectSignals(),
            .webkit => |wp| wp.disconnectSignals(),
        }
    }

    pub fn destroy(self: Panel, alloc: std.mem.Allocator) void {
        switch (self) {
            .terminal => |p| p.destroy(alloc),
            .webkit => |wp| wp.destroy(),
        }
    }

    pub fn triggerFlash(self: Panel) void {
        switch (self) {
            .terminal => |p| p.triggerFlash(),
            .webkit => |wp| wp.triggerFlash(),
        }
    }

    /// Returns the terminal pane if this is a terminal panel, null otherwise.
    pub fn asTerminal(self: Panel) ?*Pane {
        return switch (self) {
            .terminal => |p| p,
            .webkit => null,
        };
    }

    /// Returns the web panel if this is a webkit panel, null otherwise.
    pub fn asWebPanel(self: Panel) ?*WebPanel {
        return switch (self) {
            .webkit => |wp| wp,
            else => null,
        };
    }
};
