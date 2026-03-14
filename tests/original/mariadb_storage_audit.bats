#!/usr/bin/env bats

setup() {
  SCRIPT="/srv/www/toolkit/mariadb_storage_audit.sh"
}

@test "extract_selected_bracket_value returns selected token" {
  run bash -lc 'source "'"$SCRIPT"'"; extract_selected_bracket_value "always madvise [never]"'
  [ "$status" -eq 0 ]
  [ "$output" = "never" ]
}

@test "normalize_numeric_value trims spaces" {
  run bash -lc 'source "'"$SCRIPT"'"; normalize_numeric_value "  128  "'
  [ "$status" -eq 0 ]
  [ "$output" = "128" ]
}

@test "normalize_numeric_value rejects non numeric values" {
  run bash -lc 'source "'"$SCRIPT"'"; normalize_numeric_value "128k"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "choose_scheduler returns none for nvme" {
  run bash -lc 'source "'"$SCRIPT"'"; get_disk_name() { echo nvme0n1; }; choose_scheduler'
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "choose_scheduler returns mq-deadline for non nvme" {
  run bash -lc 'source "'"$SCRIPT"'"; get_disk_name() { echo sdb; }; choose_scheduler'
  [ "$status" -eq 0 ]
  [ "$output" = "mq-deadline" ]
}

@test "status_for_value_equal returns ok for normalized numeric file" {
  run bash -lc 'source "'"$SCRIPT"'"; tmp=$(mktemp); printf "15\n" > "$tmp"; status_for_value_equal "$tmp" 15; rm -f "$tmp"'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}
