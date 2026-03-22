#!/usr/bin/bash
#
#   sqlite.sh - Confirm presence of sqlite3 binary
#
#   Copyright (c) 2026 Songbird-Project <vaelixd@proton.me>
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

[[ -n "$LIBMAKEPKG_EXECUTABLE_PACMAN_SH" ]] && return
LIBMAKEPKG_EXECUTABLE_PACMAN_SH=1

MAKEPKG_LIBRARY=${MAKEPKG_LIBRARY:-'/usr/share/makepkg'}

source "$MAKEPKG_LIBRARY/util/message.sh"

executable_functions+=('executable_sqlite')

executable_sqlite() {
  if ! type -p sqlite3 >/dev/null; then
    error "$(gettext "Cannot find the %s binary required for querying the libnest packages database.")" "sqlite3"
    return 1
  fi
}
