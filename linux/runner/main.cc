#include "my_application.h"
#include <stdlib.h>

int main(int argc, char** argv) {
  // Force X11 backend to ensure taskbar icons work correctly on Wayland
  // during development (flutter run). Wayland requires installed .desktop files
  // for icons, which dev builds lack. X11 sends the icon bitmap directly.
  setenv("GDK_BACKEND", "x11", 0);
  
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
