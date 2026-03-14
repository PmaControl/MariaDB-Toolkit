#!/usr/bin/env bash

menu_wc_width() {
  local text="$1"
  printf '%s' "$text" | wc -m | tr -d ' '
}

menu_repeat_char() {
  local ch="$1"
  local count="$2"
  local buf

  printf -v buf '%*s' "$count" ''
  printf '%s' "${buf// /$ch}"
}

menu_item_label_for_lang() {
  local forced_lang="$1"
  local index="$2"
  menu_text_for_lang "$forced_lang" "${MENU_ITEM_KEYS[$index]}"
}

menu_compute_inner_width() {
  local forced_lang key text width max_width=0
  local i

  for forced_lang in "${MENU_LANG_CODES[@]}"; do
    for key in title hint language_label action_label; do
      text="$(menu_text_for_lang "$forced_lang" "$key")"
      [[ "$key" == "title" ]] && text=" ${text} "
      width="$(menu_wc_width "$text")"
      (( width > max_width )) && max_width="$width"
    done

    for i in "${!MENU_ITEM_KEYS[@]}"; do
      text="> $(menu_item_label_for_lang "$forced_lang" "$i")"
      width="$(menu_wc_width "$text")"
      (( width > max_width )) && max_width="$width"
    done
  done

  text=""
  for i in "${!MENU_LANG_LABELS[@]}"; do
    text+=" ${MENU_LANG_LABELS[$i]} "
  done
  width="$(menu_wc_width "$text")"
  (( width > max_width )) && max_width="$width"

  echo $((max_width + 2))
}

menu_center_text() {
  local width="$1"
  local text="$2"
  local text_width left_pad right_pad

  text_width="$(menu_wc_width "$text")"
  (( text_width > width )) && text_width="$width"
  left_pad=$(((width - text_width) / 2))
  right_pad=$((width - text_width - left_pad))
  printf '%*s%s%*s' "$left_pad" '' "$text" "$right_pad" ''
}

menu_box_line() {
  local row="$1"
  local raw_text="$2"
  local rendered_text="$3"
  local raw_width pad

  raw_width="$(menu_wc_width "$raw_text")"
  pad=$((MENU_INNER_W - raw_width))
  (( pad < 0 )) && pad=0

  tput cup "$row" "$MENU_LEFT"
  printf "%b %b%*s %b" "${BOLD}${BLUE}|${NC}" "$rendered_text" "$pad" "" "${BOLD}${BLUE}|${NC}"
}

menu_draw_static_frame() {
  local cols lines box_w box_h top border title hint
  local i

  cols="$(tput cols 2>/dev/null || echo 80)"
  lines="$(tput lines 2>/dev/null || echo 24)"

  MENU_INNER_W="$(menu_compute_inner_width)"
  box_w=$((MENU_INNER_W + 2))
  box_h=$((14 + ${#MENU_ITEM_KEYS[@]}))
  (( box_w < 44 )) && box_w=44
  (( box_w > cols - 2 )) && box_w=$((cols - 2))
  MENU_INNER_W=$((box_w - 2))
  MENU_LEFT=$(((cols - box_w) / 2))
  top=$(((lines - box_h) / 2))
  (( top < 0 )) && top=0
  MENU_TOP="$top"
  MENU_LANG_ROW=$((MENU_TOP + 6))
  MENU_ACTION_START_ROW=$((MENU_TOP + 9))

  border="$(menu_repeat_char "-" "$MENU_INNER_W")"
  printf '\033[H\033[2J'
  tput cup "$MENU_TOP" "$MENU_LEFT"
  printf "%b+%s+%b" "${BOLD}${BLUE}" "$border" "${NC}"

  title="$(menu_text_for_lang "${MENU_LANG_CODES[$MENU_LANG_IDX]}" title)"
  menu_box_line $((MENU_TOP + 1)) "$title" "${REV}${BOLD}$(menu_center_text "$MENU_INNER_W" "$title")${NC}"

  tput cup $((MENU_TOP + 2)) "$MENU_LEFT"
  printf "%b+%s+%b" "${BOLD}${BLUE}" "$border" "${NC}"

  hint="$(menu_text_for_lang "${MENU_LANG_CODES[$MENU_LANG_IDX]}" hint)"
  menu_box_line $((MENU_TOP + 3)) "$hint" "${DIM}${hint}${NC}"
  menu_box_line $((MENU_TOP + 4)) "" ""
  menu_box_line $((MENU_TOP + 5)) "$(menu_text_for_lang "${MENU_LANG_CODES[$MENU_LANG_IDX]}" language_label)" "${BOLD}${CYAN}$(menu_text_for_lang "${MENU_LANG_CODES[$MENU_LANG_IDX]}" language_label)${NC}"
  menu_box_line $((MENU_TOP + 7)) "" ""
  menu_box_line $((MENU_TOP + 8)) "$(menu_text_for_lang "${MENU_LANG_CODES[$MENU_LANG_IDX]}" action_label)" "${BOLD}${CYAN}$(menu_text_for_lang "${MENU_LANG_CODES[$MENU_LANG_IDX]}" action_label)${NC}"

  for i in "${!MENU_ITEM_KEYS[@]}"; do
    menu_box_line $((MENU_ACTION_START_ROW + i)) "" ""
  done

  menu_box_line $((MENU_TOP + box_h - 2)) "" "${DIM}$(menu_center_text "$MENU_INNER_W" "Enter confirm | q quit")${NC}"
  tput cup $((MENU_TOP + box_h - 1)) "$MENU_LEFT"
  printf "%b+%s+%b" "${BOLD}${BLUE}" "$border" "${NC}"
}

menu_render_language_row() {
  local i raw="" rendered=""

  for i in "${!MENU_LANG_LABELS[@]}"; do
    raw+="[${MENU_LANG_LABELS[$i]}] "
    if [[ "$i" -eq "$MENU_LANG_IDX" ]]; then
      rendered+="${REV}${BOLD}[${MENU_LANG_LABELS[$i]}]${NC} "
    else
      rendered+="${BOLD}${CYAN}[${MENU_LANG_LABELS[$i]}]${NC} "
    fi
  done

  raw="${raw%" "}"
  rendered="${rendered%" "}"
  menu_box_line "$MENU_LANG_ROW" "$raw" "$rendered"
}

menu_render_item_row() {
  local idx="$1"
  local lang="${MENU_LANG_CODES[$MENU_LANG_IDX]}"
  local label raw rendered row

  label="$(menu_item_label_for_lang "$lang" "$idx")"
  row=$((MENU_ACTION_START_ROW + idx))
  if [[ "$idx" -eq "$MENU_SELECTED_IDX" ]]; then
    raw="> ${label}"
    rendered="${REV}${BOLD}${GREEN}> ${label}${NC}"
  else
    raw="  ${label}"
    rendered="$raw"
  fi
  menu_box_line "$row" "$raw" "$rendered"
}

menu_render_dynamic() {
  local i
  local lang="${MENU_LANG_CODES[$MENU_LANG_IDX]}"
  local title hint language_label action_label footer

  title="$(menu_text_for_lang "$lang" title)"
  hint="$(menu_text_for_lang "$lang" hint)"
  language_label="$(menu_text_for_lang "$lang" language_label)"
  action_label="$(menu_text_for_lang "$lang" action_label)"
  footer="Enter confirm | q quit"

  menu_box_line $((MENU_TOP + 1)) "$title" "${REV}${BOLD}$(menu_center_text "$MENU_INNER_W" "$title")${NC}"
  menu_box_line $((MENU_TOP + 3)) "$hint" "${DIM}${hint}${NC}"
  menu_box_line $((MENU_TOP + 5)) "$language_label" "${BOLD}${CYAN}${language_label}${NC}"
  menu_box_line $((MENU_TOP + 8)) "$action_label" "${BOLD}${CYAN}${action_label}${NC}"
  menu_box_line $((MENU_TOP + 12 + ${#MENU_ITEM_KEYS[@]})) "$footer" "${DIM}$(menu_center_text "$MENU_INNER_W" "$footer")${NC}"
  menu_render_language_row

  for i in "${!MENU_ITEM_KEYS[@]}"; do
    menu_render_item_row "$i"
  done
}

menu_read_key() {
  local key next seq ch

  IFS= read -rsn1 key
  case "$key" in
    '')
      echo "ENTER"
      ;;
    q|Q)
      echo "QUIT"
      ;;
    $'\x1b')
      if ! IFS= read -rsn1 -t 0.20 next; then
        echo "OTHER"
        return
      fi
      if [[ "$next" != "[" && "$next" != "O" ]]; then
        echo "OTHER"
        return
      fi
      seq="$next"
      while IFS= read -rsn1 -t 0.05 ch; do
        seq+="$ch"
        [[ "$ch" =~ [A-Za-z~] ]] && break
      done
      case "$seq" in
        "[A"|OA) echo "UP" ;;
        "[B"|OB) echo "DOWN" ;;
        "[C"|OC|\[*C) echo "RIGHT" ;;
        "[D"|OD|\[*D) echo "LEFT" ;;
        *) echo "OTHER" ;;
      esac
      ;;
    *)
      echo "OTHER"
      ;;
  esac
}

menu_terminal_setup() {
  MENU_STTY_STATE="$(stty -g 2>/dev/null || true)"
  if command_exists tput; then
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
  fi
}

menu_terminal_restore() {
  if command_exists tput; then
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
  fi
  if [[ -n "${MENU_STTY_STATE:-}" ]]; then
    stty "${MENU_STTY_STATE}" 2>/dev/null || true
  fi
}

run_interactive_menu() {
  local key previous_lang previous_selected

  MENU_SELECTED_IDX=0
  MENU_LANG_IDX=0
  for previous_lang in "${!MENU_LANG_CODES[@]}"; do
    if [[ "${HELP_LANG,,}" == "${MENU_LANG_CODES[$previous_lang]}"* ]]; then
      MENU_LANG_IDX="$previous_lang"
      break
    fi
  done

  menu_terminal_setup
  trap menu_terminal_restore RETURN

  menu_draw_static_frame
  menu_render_dynamic

  while true; do
    key="$(menu_read_key)"
    previous_lang="$MENU_LANG_IDX"
    previous_selected="$MENU_SELECTED_IDX"

    case "$key" in
      UP)
        (( MENU_SELECTED_IDX > 0 )) && ((MENU_SELECTED_IDX -= 1))
        ;;
      DOWN)
        (( MENU_SELECTED_IDX < ${#MENU_ITEM_KEYS[@]} - 1 )) && ((MENU_SELECTED_IDX += 1))
        ;;
      RIGHT)
        (( MENU_LANG_IDX < ${#MENU_LANG_CODES[@]} - 1 )) && ((MENU_LANG_IDX += 1))
        ;;
      LEFT)
        (( MENU_LANG_IDX > 0 )) && ((MENU_LANG_IDX -= 1))
        ;;
      ENTER)
        HELP_LANG="${MENU_LANG_CODES[$MENU_LANG_IDX]}"
        MODE="${MENU_ITEM_MODES[$MENU_SELECTED_IDX]}"
        [[ "$MODE" == "__quit__" ]] && exit 0
        return 0
        ;;
      QUIT)
        exit 0
        ;;
    esac

    if [[ "$previous_lang" != "$MENU_LANG_IDX" ]]; then
      HELP_LANG="${MENU_LANG_CODES[$MENU_LANG_IDX]}"
      menu_render_dynamic
    elif [[ "$previous_selected" != "$MENU_SELECTED_IDX" ]]; then
      menu_render_item_row "$previous_selected"
      menu_render_item_row "$MENU_SELECTED_IDX"
    fi
  done
}
