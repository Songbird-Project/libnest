#!/bin/bash
#
#  db.sh - utilities for querying the libnest package database
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

LIBNEST_PATH=${LIBNEST_PATH:-'/etc/nest/'}
LIBNEST_DB=${LIBNEST_DB:-'pkgs.db'}

check_missing() {
  local deps=("$@")

  local dep_names=()
  for dep in "${deps[@]}"; do
    dep_names+=("$(echo "$dep" | sed 's/[<>=].*//')")
  done

  local values_list
  values_list=$(printf "('%s')," "${dep_names[@]}")
  values_list=${values_list%,}

  local missing
  missing=$(
    sqlite3 "$LIBNEST_PATH/$LIBNEST_DB" "
    WITH tmp(dep) AS (
      VALUES $values_list
    )
    SELECT dep
    FROM tmp
    WHERE NOT EXISTS (
      SELECT 1
      FROM installed
      WHERE installed.name = tmp.dep
         OR EXISTS (
           SELECT 1
           FROM json_each(installed.metadata, '\$.provides')
           WHERE json_each.value = tmp.dep
         )
    );
    "
  )

  IFS=$'\n' read -r -d '' -a missing_array <<<"$missing"$'\0'

  if ((${#missing_array[@]} > 0)); then
    printf "%s\n" "${missing_array[@]}"
    return 127
  fi

  return 0
}

get_installed() {
  sqlite3 "$LIBNEST_PATH/$LIBNEST_DB" "SELECT name FROM installed"
}
