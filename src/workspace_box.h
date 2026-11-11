#pragma once

#include <gtk/gtk.h>

GtkWidget *seance_workspace_box_new(GtkOrientation orientation, int spacing);
void seance_workspace_box_set_notify(GtkWidget *widget,
                                     void (*notify)(gpointer user_data, int width, int height),
                                     gpointer user_data);
unsigned long seance_workspace_box_allocations(GtkWidget *widget);
