#include "workspace_box.h"

typedef void (*SeanceWorkspaceBoxNotify)(gpointer user_data, int width, int height);

typedef struct {
    GtkBox parent_instance;
    SeanceWorkspaceBoxNotify notify;
    gpointer notify_data;
    unsigned long allocations;
} SeanceWorkspaceBox;

typedef struct {
    GtkBoxClass parent_class;
} SeanceWorkspaceBoxClass;

G_DEFINE_TYPE(SeanceWorkspaceBox, seance_workspace_box, GTK_TYPE_BOX)

static void seance_workspace_box_size_allocate(GtkWidget *widget, int width, int height, int baseline) {
    GTK_WIDGET_CLASS(seance_workspace_box_parent_class)->size_allocate(widget, width, height, baseline);

    SeanceWorkspaceBox *self = (SeanceWorkspaceBox *)widget;
    self->allocations++;
    if (self->notify != NULL && width > 0 && height > 0) {
        self->notify(self->notify_data, width, height);
    }
}

static void seance_workspace_box_class_init(SeanceWorkspaceBoxClass *klass) {
    GTK_WIDGET_CLASS(klass)->size_allocate = seance_workspace_box_size_allocate;
}

static void seance_workspace_box_init(SeanceWorkspaceBox *self) {
    (void)self;
}

GtkWidget *seance_workspace_box_new(GtkOrientation orientation, int spacing) {
    return GTK_WIDGET(g_object_new(seance_workspace_box_get_type(),
                                   "orientation", orientation,
                                   "spacing", spacing,
                                   NULL));
}

void seance_workspace_box_set_notify(GtkWidget *widget, SeanceWorkspaceBoxNotify notify, gpointer user_data) {
    SeanceWorkspaceBox *self = (SeanceWorkspaceBox *)widget;
    self->notify = notify;
    self->notify_data = user_data;
}

unsigned long seance_workspace_box_allocations(GtkWidget *widget) {
    return ((SeanceWorkspaceBox *)widget)->allocations;
}
