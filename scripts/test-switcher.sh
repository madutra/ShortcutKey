#!/bin/bash
# Abre o alternador por 4 segundos (útil para testar a aparência sem teclado/trackpad).
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("app.shortcutkey.debug.showSwitcher"), object: nil, userInfo: nil, deliverImmediately: true)'
