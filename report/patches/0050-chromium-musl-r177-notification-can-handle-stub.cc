// Diagnostic-only source used by the R177 isolated link.
#include "chrome/browser/notifications/notification_platform_bridge.h"

bool NotificationPlatformBridge::CanHandleType(
    NotificationHandler::Type type) {
  return type != NotificationHandler::Type::TRANSIENT;
}
