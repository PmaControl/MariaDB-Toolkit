#!/usr/bin/env bash
set -euo pipefail

declare -Ag CACHE=()
CACHE_ENABLED=1

############################################
# MariaDB storage audit + Linux tuning
#
# Modes:
#   no args    : interactive menu
#   --check    : audit only
#   --dry-run  : show commands and file writes
#   --apply    : apply sysctl/thp/scheduler/block/fstab tuning
#   --help     : detailed multilingual help
#   --author   : show author information
#   --license  : show license information
#   --version  : show script version
#   --install-man : install man page for `man mariadb_storage_audit`
#
# Notes:
# - Detects MariaDB datadir dynamically
# - Shows pre/post checks and multilingual terminal UI
# - Provides an interactive menu with keyboard navigation
# - Adds optimized fstab options for ext4 only
# - Does NOT move MariaDB data automatically
# - Does NOT change MariaDB datadir automatically
# - Reads MariaDB for diagnostics but applies Linux system settings only
############################################

MODE="--check"
HELP_LANG=""
SCRIPT_VERSION="Version 1"
SCRIPT_DATE="2026-03-14"
AUTHOR_NAME="Aurélien LEQUOY"
AUTHOR_EMAIL="aurelien@pmacontrol.com"
AUTHOR_URL="http://www.pmacontrol.com"
SCRIPT_LICENSE="GPL-v3"

TARGET_DEVICE="/dev/sdb1"
TARGET_MOUNT="/srv/mysql"
ALT_TARGET_MOUNT="/data/mysql"

DEFAULT_FS_TYPE="ext4"
DEFAULT_MOUNT_OPTS="defaults,noatime,nodiratime"
EXT4_MOUNT_OPTS="defaults,noatime,nodiratime,errors=remount-ro"

SYSCTL_FILE="/etc/sysctl.d/99-mariadb-tuning.conf"
THP_SERVICE="/etc/systemd/system/disable-thp.service"
UDEV_RULE="/etc/udev/rules.d/60-io-scheduler.rules"
FSTAB_FILE="/etc/fstab"
MANPAGE_SOURCE="docs/mariadb_storage_audit.1"
MANPAGE_DIR="/usr/local/share/man/man1"
MANPAGE_TARGET="${MANPAGE_DIR}/mariadb_storage_audit.1.gz"

# Tunables
SWAPPINESS="1"
DIRTY_RATIO="15"
DIRTY_BACKGROUND_RATIO="5"
VFS_CACHE_PRESSURE="50"
NR_REQUESTS_DEFAULT="1024"
LIMIT_NOFILE_EXPECTED="200000"
NUMA_BALANCING_EXPECTED="0"
INNODB_FLUSH_METHOD_EXPECTED="O_DIRECT"
STATUS_LABEL_WIDTH="54"

GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
REV=$'\033[7m'
NC=$'\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*"; }
step() { echo -e "\n${REV}${BOLD} $* ${NC}"; }

kv_line() {
  local label="$1"
  local value="$2"
  local padded_label
  padded_label="$(pad_label "$label" 22)"
  printf "${BOLD}${CYAN}%s${NC} : %s\n" "$padded_label" "$value"
}

cache_get() {
  local key="$1"
  shift

  if [[ "${CACHE_ENABLED}" != "1" ]]; then
    "$@"
    return
  fi

  if [[ -v CACHE["$key"] ]]; then
    printf '%s\n' "${CACHE[$key]}"
    return
  fi

  CACHE["$key"]="$("$@")"
  printf '%s\n' "${CACHE[$key]}"
}

cache_invalidate() {
  local prefix="$1"
  local key

  for key in "${!CACHE[@]}"; do
    if [[ "$key" == "$prefix"* ]]; then
      unset 'CACHE[$key]'
    fi
  done
}

cache_reset_all() {
  CACHE=()
}

read_file_uncached() {
  cat "$1" 2>/dev/null || true
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "$(msg err_root)"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_help_lang() {
  local raw
  raw="${HELP_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}}"
  raw="${raw,,}"

  case "$raw" in
    fr*|french*)
      echo "fr"
      ;;
    ru*|russian*)
      echo "ru"
      ;;
    zh*|cn*|chinese*)
      echo "zh"
      ;;
    *)
      echo "en"
      ;;
  esac
}

lang() {
  detect_help_lang
}

msg() {
  local key="$1"
  case "$(lang):$key" in
    fr:err_root) echo "Ce script doit être exécuté en root." ;;
    en:err_root) echo "This script must be run as root." ;;
    ru:err_root) echo "Этот скрипт должен запускаться от root." ;;
    zh:err_root) echo "此脚本必须以 root 身份运行。" ;;
    fr:err_missing_lang) echo "Valeur manquante pour --lang" ;;
    en:err_missing_lang) echo "Missing value for --lang" ;;
    ru:err_missing_lang) echo "Отсутствует значение для --lang" ;;
    zh:err_missing_lang) echo "--lang 缺少取值" ;;
    fr:see_help) echo "Voir l'aide: $0 --help" ;;
    en:see_help) echo "See help: $0 --help" ;;
    ru:see_help) echo "См. справку: $0 --help" ;;
    zh:see_help) echo "查看帮助：$0 --help" ;;
    fr:err_unknown_option) echo "Option inconnue: $2" ;;
    en:err_unknown_option) echo "Unknown option: $2" ;;
    ru:err_unknown_option) echo "Неизвестная опция: $2" ;;
    zh:err_unknown_option) echo "未知选项：$2" ;;
    fr:err_missing_device) echo "Le périphérique $2 n'existe pas." ;;
    en:err_missing_device) echo "Device $2 does not exist." ;;
    ru:err_missing_device) echo "Устройство $2 не существует." ;;
    zh:err_missing_device) echo "设备 $2 不存在。" ;;
    fr:summary_target) echo "RÉSUMÉ CIBLE" ;;
    en:summary_target) echo "TARGET SUMMARY" ;;
    ru:summary_target) echo "СВОДКА ПО ЦЕЛИ" ;;
    zh:summary_target) echo "目标摘要" ;;
    fr:preamble_storage) echo "PRÉAMBULE STOCKAGE MYSQL/MARIADB" ;;
    en:preamble_storage) echo "MYSQL/MARIADB STORAGE PREAMBLE" ;;
    ru:preamble_storage) echo "ПРЕАМБУЛА ХРАНИЛИЩА MYSQL/MARIADB" ;;
    zh:preamble_storage) echo "MYSQL/MARIADB 存储前置检查" ;;
    fr:state_before) echo "ÉTAT AVANT" ;;
    en:state_before) echo "STATE BEFORE" ;;
    ru:state_before) echo "СОСТОЯНИЕ ДО" ;;
    zh:state_before) echo "应用前状态" ;;
    fr:checklist_before) echo "CHECK-LIST AVANT" ;;
    en:checklist_before) echo "CHECKLIST BEFORE" ;;
    ru:checklist_before) echo "ПРОВЕРКИ ДО" ;;
    zh:checklist_before) echo "应用前检查清单" ;;
    fr:checklist_after) echo "CHECK-LIST APRÈS" ;;
    en:checklist_after) echo "CHECKLIST AFTER" ;;
    ru:checklist_after) echo "ПРОВЕРКИ ПОСЛЕ" ;;
    zh:checklist_after) echo "应用后检查清单" ;;
    fr:application) echo "APPLICATION" ;;
    en:application) echo "APPLY" ;;
    ru:application) echo "ПРИМЕНЕНИЕ" ;;
    zh:application) echo "执行应用" ;;
    fr:mode_check) echo "MODE CHECK" ;;
    en:mode_check) echo "CHECK MODE" ;;
    ru:mode_check) echo "РЕЖИМ ПРОВЕРКИ" ;;
    zh:mode_check) echo "检查模式" ;;
    fr:mode_dry_run) echo "MODE DRY-RUN" ;;
    en:mode_dry_run) echo "DRY-RUN MODE" ;;
    ru:mode_dry_run) echo "РЕЖИМ DRY-RUN" ;;
    zh:mode_dry_run) echo "DRY-RUN 模式" ;;
    fr:state_after) echo "ÉTAT APRÈS" ;;
    en:state_after) echo "STATE AFTER" ;;
    ru:state_after) echo "СОСТОЯНИЕ ПОСЛЕ" ;;
    zh:state_after) echo "应用后状态" ;;
    fr:none_applied) echo "Aucune modification appliquée." ;;
    en:none_applied) echo "No changes applied." ;;
    ru:none_applied) echo "Изменения не применялись." ;;
    zh:none_applied) echo "未应用任何修改。" ;;
    fr:apply_hint) echo "Pour appliquer : $0 --apply" ;;
    en:apply_hint) echo "To apply: $0 --apply" ;;
    ru:apply_hint) echo "Для применения: $0 --apply" ;;
    zh:apply_hint) echo "如需应用：$0 --apply" ;;
    fr:cmds_would_run) echo "Commandes et écritures qui seraient exécutées par --apply :" ;;
    en:cmds_would_run) echo "Commands and file writes that would be executed by --apply:" ;;
    ru:cmds_would_run) echo "Команды и записи в файлы, которые выполнил бы --apply:" ;;
    zh:cmds_would_run) echo "--apply 将执行的命令与文件写入如下：" ;;
    fr:verify_after_apply) echo "Relecture après application" ;;
    en:verify_after_apply) echo "Verification after apply" ;;
    ru:verify_after_apply) echo "Проверка после применения" ;;
    zh:verify_after_apply) echo "应用后校验" ;;
    fr:dryrun_sysctl) echo "Sysctl" ;;
    en:dryrun_sysctl) echo "Sysctl" ;;
    ru:dryrun_sysctl) echo "Параметры sysctl" ;;
    zh:dryrun_sysctl) echo "sysctl 参数" ;;
    fr:dryrun_thp) echo "THP" ;;
    en:dryrun_thp) echo "THP" ;;
    ru:dryrun_thp) echo "Transparent Huge Pages (THP)" ;;
    zh:dryrun_thp) echo "透明大页（THP）" ;;
    fr:dryrun_scheduler) echo "Scheduler" ;;
    en:dryrun_scheduler) echo "Scheduler" ;;
    ru:dryrun_scheduler) echo "Планировщик ввода-вывода" ;;
    zh:dryrun_scheduler) echo "I/O 调度器" ;;
    fr:dryrun_block) echo "Block settings" ;;
    en:dryrun_block) echo "Block settings" ;;
    ru:dryrun_block) echo "Параметры блочного устройства" ;;
    zh:dryrun_block) echo "块设备参数" ;;
    fr:dryrun_fstab) echo "fstab" ;;
    en:dryrun_fstab) echo "fstab" ;;
    ru:dryrun_fstab) echo "fstab" ;;
    zh:dryrun_fstab) echo "fstab" ;;
    fr:write_file) echo "write" ;;
    en:write_file) echo "write" ;;
    ru:write_file) echo "записать в" ;;
    zh:write_file) echo "写入" ;;
    fr:fallback_cmd) echo "fallback" ;;
    en:fallback_cmd) echo "fallback" ;;
    ru:fallback_cmd) echo "резервный вариант" ;;
    zh:fallback_cmd) echo "回退方案" ;;
    fr:append_to) echo "append to" ;;
    en:append_to) echo "append to" ;;
    ru:append_to) echo "добавить в" ;;
    zh:append_to) echo "追加到" ;;
    fr:reread_after_apply) echo "Re-read sysctl, THP, scheduler, read_ahead_kb, nr_requests and fstab" ;;
    en:reread_after_apply) echo "Re-read sysctl, THP, scheduler, read_ahead_kb, nr_requests and fstab" ;;
    ru:reread_after_apply) echo "Повторно прочитать sysctl, THP, планировщик ввода-вывода, read_ahead_kb, nr_requests и fstab" ;;
    zh:reread_after_apply) echo "重新读取 sysctl、THP、调度器、read_ahead_kb、nr_requests 和 fstab" ;;
    fr:err_apply_not_conform) echo "Au moins un réglage appliqué n'est pas conforme après relecture." ;;
    en:err_apply_not_conform) echo "At least one applied setting is not compliant after re-read." ;;
    ru:err_apply_not_conform) echo "Как минимум одна применённая настройка не соответствует ожидаемому значению после повторной проверки." ;;
    zh:err_apply_not_conform) echo "至少有一项已应用设置在重新校验后仍不符合预期。" ;;
    fr:label_service_active) echo "MariaDB actif" ;;
    en:label_service_active) echo "MariaDB active" ;;
    ru:label_service_active) echo "MariaDB активна" ;;
    fr:label_datadir_detected) echo "Datadir détecté" ;;
    en:label_datadir_detected) echo "Datadir detected" ;;
    ru:label_datadir_detected) echo "Datadir обнаружен" ;;
    fr:label_datadir_separate_fs) echo "Datadir sur un FS séparé de /" ;;
    en:label_datadir_separate_fs) echo "Datadir on a filesystem separate from /" ;;
    ru:label_datadir_separate_fs) echo "Datadir на отдельной файловой системе от /" ;;
    fr:label_mountpoint_identified) echo "Point de montage du datadir identifié" ;;
    en:label_mountpoint_identified) echo "Datadir mountpoint identified" ;;
    ru:label_mountpoint_identified) echo "Точка монтирования datadir определена" ;;
    fr:label_target_device_present) echo "Device cible présent" ;;
    en:label_target_device_present) echo "Target device present" ;;
    ru:label_target_device_present) echo "Целевое устройство присутствует" ;;
    zh:label_target_device_present) echo "目标设备存在" ;;
    fr:label_target_uuid_present) echo "UUID du device cible détecté" ;;
    en:label_target_uuid_present) echo "Target device UUID detected" ;;
    ru:label_target_uuid_present) echo "UUID целевого устройства обнаружен" ;;
    fr:label_target_fs_present) echo "Filesystem du device cible détecté" ;;
    en:label_target_fs_present) echo "Target device filesystem detected" ;;
    ru:label_target_fs_present) echo "Файловая система целевого устройства обнаружена" ;;
    fr:label_datadir_fstab_present) echo "Mount du datadir présent dans fstab" ;;
    en:label_datadir_fstab_present) echo "Datadir mount present in fstab" ;;
    ru:label_datadir_fstab_present) echo "Монтирование datadir присутствует в fstab" ;;
    fr:label_datadir_fstab_opts) echo "Options du mount datadir optimisées dans fstab" ;;
    en:label_datadir_fstab_opts) echo "Datadir mount options optimized in fstab" ;;
    ru:label_datadir_fstab_opts) echo "Опции монтирования datadir оптимизированы в fstab" ;;
    fr:label_datadir_mounted) echo "Mount du datadir actuellement monté" ;;
    en:label_datadir_mounted) echo "Datadir mount currently mounted" ;;
    ru:label_datadir_mounted) echo "Монтирование datadir сейчас активно" ;;
    fr:label_numa) echo "numa_balancing désactivé [$NUMA_BALANCING_EXPECTED]" ;;
    en:label_numa) echo "numa_balancing disabled [$NUMA_BALANCING_EXPECTED]" ;;
    ru:label_numa) echo "numa_balancing отключён [$NUMA_BALANCING_EXPECTED]" ;;
    fr:label_scheduler) echo "Scheduler disque correct [$(scheduler_expectation_label)]" ;;
    en:label_scheduler) echo "Disk scheduler correct [$(scheduler_expectation_label)]" ;;
    ru:label_scheduler) echo "Планировщик диска корректен [$(scheduler_expectation_label)]" ;;
    fr:label_readahead) echo "read_ahead_kb correct [$(suggest_readahead_kb)]" ;;
    en:label_readahead) echo "read_ahead_kb correct [$(suggest_readahead_kb)]" ;;
    ru:label_readahead) echo "read_ahead_kb корректен [$(suggest_readahead_kb)]" ;;
    fr:label_nr_requests) echo "nr_requests correct [$(suggest_nr_requests)]" ;;
    en:label_nr_requests) echo "nr_requests correct [$(suggest_nr_requests)]" ;;
    ru:label_nr_requests) echo "nr_requests корректен [$(suggest_nr_requests)]" ;;
    fr:label_limitnofile) echo "LimitNOFILE correct [>=${LIMIT_NOFILE_EXPECTED}]" ;;
    en:label_limitnofile) echo "LimitNOFILE correct [>=${LIMIT_NOFILE_EXPECTED}]" ;;
    ru:label_limitnofile) echo "LimitNOFILE корректен [>=${LIMIT_NOFILE_EXPECTED}]" ;;
    fr:label_innodb_flush_method) echo "innodb_flush_method correct [${INNODB_FLUSH_METHOD_EXPECTED}]" ;;
    en:label_innodb_flush_method) echo "innodb_flush_method correct [${INNODB_FLUSH_METHOD_EXPECTED}]" ;;
    ru:label_innodb_flush_method) echo "innodb_flush_method корректен [${INNODB_FLUSH_METHOD_EXPECTED}]" ;;
    fr:yes) echo "OUI" ;;
    en:yes) echo "YES" ;;
    ru:yes) echo "ДА" ;;
    zh:yes) echo "是" ;;
    fr:no) echo "NON" ;;
    en:no) echo "NO" ;;
    ru:no) echo "НЕТ" ;;
    zh:no) echo "否" ;;
    fr:cpu_load) echo "CPU load" ;;
    en:cpu_load) echo "CPU load" ;;
    ru:cpu_load) echo "Нагрузка CPU" ;;
    zh:cpu_load) echo "CPU 负载" ;;
    fr:memory) echo "Mémoire" ;;
    en:memory) echo "Memory" ;;
    ru:memory) echo "Память" ;;
    zh:memory) echo "内存" ;;
    fr:swap_devices) echo "Swap devices" ;;
    en:swap_devices) echo "Swap devices" ;;
    ru:swap_devices) echo "Swap устройства" ;;
    zh:swap_devices) echo "Swap 设备" ;;
    fr:disks) echo "Disques" ;;
    en:disks) echo "Disks" ;;
    ru:disks) echo "Диски" ;;
    zh:disks) echo "磁盘" ;;
    fr:datadir_mariadb) echo "Datadir MariaDB" ;;
    en:datadir_mariadb) echo "MariaDB datadir" ;;
    ru:datadir_mariadb) echo "Datadir MariaDB" ;;
    zh:datadir_mariadb) echo "MariaDB 数据目录" ;;
    fr:mountpoint) echo "Point de montage" ;;
    en:mountpoint) echo "Mountpoint" ;;
    ru:mountpoint) echo "Точка монтирования" ;;
    fr:source) echo "Source" ;;
    en:source) echo "Source" ;;
    ru:source) echo "Источник" ;;
    fr:filesystem) echo "Filesystem" ;;
    en:filesystem) echo "Filesystem" ;;
    ru:filesystem) echo "Файловая система" ;;
    zh:filesystem) echo "文件系统" ;;
    fr:usage) echo "Occupation" ;;
    en:usage) echo "Usage" ;;
    ru:usage) echo "Использование" ;;
    fr:target_fstab_entry) echo "Entrée fstab cible" ;;
    en:target_fstab_entry) echo "Target fstab entry" ;;
    ru:target_fstab_entry) echo "Целевая запись fstab" ;;
    zh:target_fstab_entry) echo "目标 fstab 条目" ;;
    fr:proposed_line) echo "Ligne proposée" ;;
    en:proposed_line) echo "Proposed line" ;;
    ru:proposed_line) echo "Предлагаемая строка" ;;
    zh:proposed_line) echo "建议条目" ;;
    fr:mounted_target) echo "Montage ${TARGET_MOUNT}" ;;
    en:mounted_target) echo "Mount ${TARGET_MOUNT}" ;;
    ru:mounted_target) echo "Монтирование ${TARGET_MOUNT}" ;;
    zh:mounted_target) echo "挂载点 ${TARGET_MOUNT}" ;;
    fr:mount_options) echo "Options de montage" ;;
    en:mount_options) echo "Mount options" ;;
    ru:mount_options) echo "Параметры монтирования" ;;
    zh:mount_options) echo "挂载选项" ;;
    fr:test_mount_a) echo "Test mount -a" ;;
    en:test_mount_a) echo "mount -a test" ;;
    ru:test_mount_a) echo "Проверка mount -a" ;;
    fr:ok) echo "OK" ;;
    en:ok) echo "OK" ;;
    ru:ok) echo "OK" ;;
    fr:failed) echo "ECHEC" ;;
    en:failed) echo "FAILED" ;;
    ru:failed) echo "ОШИБКА" ;;
    fr:none) echo "Aucune" ;;
    en:none) echo "None" ;;
    ru:none) echo "Нет" ;;
    fr:none_mounted) echo "Aucun" ;;
    en:none_mounted) echo "None" ;;
    ru:none_mounted) echo "Нет" ;;
    fr:hv_detected) echo "Hyperviseur détecté" ;;
    en:hv_detected) echo "Hypervisor detected" ;;
    ru:hv_detected) echo "Гипервизор обнаружен" ;;
    zh:hv_detected) echo "检测到虚拟化宿主" ;;
    fr:virtualization) echo "Virtualisation" ;;
    en:virtualization) echo "Virtualization" ;;
    ru:virtualization) echo "Виртуализация" ;;
    zh:virtualization) echo "虚拟化" ;;
    fr:datadir_nvme) echo "Datadir sur NVMe" ;;
    en:datadir_nvme) echo "Datadir on NVMe" ;;
    ru:datadir_nvme) echo "Datadir на NVMe" ;;
    zh:datadir_nvme) echo "Datadir 位于 NVMe" ;;
    fr:question_validate) echo "Question à valider" ;;
    en:question_validate) echo "Question to validate" ;;
    ru:question_validate) echo "Вопрос для уточнения" ;;
    zh:question_validate) echo "需要确认的问题" ;;
    fr:question_backend_nvme) echo "Le stockage hyperviseur du datadir est-il sur NVMe ?" ;;
    en:question_backend_nvme) echo "Is the hypervisor storage backing the datadir on NVMe?" ;;
    ru:question_backend_nvme) echo "Расположено ли хранилище гипервизора для datadir на NVMe?" ;;
    zh:question_backend_nvme) echo "datadir 所在的宿主存储是否基于 NVMe？" ;;
    fr:guest_scheduler_label) echo "Scheduler invité" ;;
    en:guest_scheduler_label) echo "Guest scheduler" ;;
    ru:guest_scheduler_label) echo "Планировщик гостя" ;;
    zh:guest_scheduler_label) echo "来宾调度器" ;;
    fr:guest_scheduler_note) echo "Recommandation par défaut = none ; impact limité côté guest sur stockage virtualisé" ;;
    en:guest_scheduler_note) echo "Default recommendation = none; guest-side impact is limited on virtualized storage" ;;
    ru:guest_scheduler_note) echo "По умолчанию рекомендуется none; влияние внутри гостя ограничено на виртуализированном хранилище" ;;
    zh:guest_scheduler_note) echo "默认建议为 none；在虚拟化存储上，来宾侧影响有限" ;;
    fr:detail) echo "Détail" ;;
    en:detail) echo "Detail" ;;
    ru:detail) echo "Детали" ;;
    zh:detail) echo "详情" ;;
    *) echo "$key" ;;
  esac
}

menu_text() {
  local key="$1"
  case "$(lang):$key" in
    fr:title) echo "MENU PRINCIPAL" ;;
    en:title) echo "MAIN MENU" ;;
    ru:title) echo "ГЛАВНОЕ МЕНЮ" ;;
    zh:title) echo "主菜单" ;;
    fr:hint) echo "Haut/Bas: action  Gauche/Droite: langue  Entrée: valider  q: quitter" ;;
    en:hint) echo "Up/Down: action  Left/Right: language  Enter: confirm  q: quit" ;;
    ru:hint) echo "Вверх/Вниз: действие  Влево/Вправо: язык  Enter: подтвердить  q: выход" ;;
    zh:hint) echo "上/下：操作  左/右：语言  回车：确认  q：退出" ;;
    fr:action_label) echo "Action" ;;
    en:action_label) echo "Action" ;;
    ru:action_label) echo "Действие" ;;
    zh:action_label) echo "操作" ;;
    fr:language_label) echo "Langue" ;;
    en:language_label) echo "Language" ;;
    ru:language_label) echo "Язык" ;;
    zh:language_label) echo "语言" ;;
    fr:opt_check) echo "Audit seulement" ;;
    en:opt_check) echo "Check only" ;;
    ru:opt_check) echo "Только проверка" ;;
    zh:opt_check) echo "仅检查" ;;
    fr:opt_dry_run) echo "Dry-run" ;;
    en:opt_dry_run) echo "Dry-run" ;;
    ru:opt_dry_run) echo "Dry-run" ;;
    zh:opt_dry_run) echo "Dry-run" ;;
    fr:opt_apply) echo "Appliquer" ;;
    en:opt_apply) echo "Apply" ;;
    ru:opt_apply) echo "Применить" ;;
    zh:opt_apply) echo "应用" ;;
    fr:opt_help) echo "Aide" ;;
    en:opt_help) echo "Help" ;;
    ru:opt_help) echo "Справка" ;;
    zh:opt_help) echo "帮助" ;;
    fr:opt_author) echo "Auteur" ;;
    en:opt_author) echo "Author" ;;
    ru:opt_author) echo "Автор" ;;
    zh:opt_author) echo "作者" ;;
    fr:opt_license) echo "Licence" ;;
    en:opt_license) echo "License" ;;
    ru:opt_license) echo "Лицензия" ;;
    zh:opt_license) echo "许可证" ;;
    fr:opt_version) echo "Version" ;;
    en:opt_version) echo "Version" ;;
    ru:opt_version) echo "Версия" ;;
    zh:opt_version) echo "版本" ;;
    fr:opt_quit) echo "Quitter" ;;
    en:opt_quit) echo "Quit" ;;
    ru:opt_quit) echo "Выход" ;;
    zh:opt_quit) echo "退出" ;;
    *) echo "$key" ;;
  esac
}

menu_text_for_lang() {
  local forced_lang="$1"
  local key="$2"
  local saved_lang="${HELP_LANG:-}"

  HELP_LANG="$forced_lang"
  menu_text "$key"
  HELP_LANG="$saved_lang"
}


parse_args() {
  local arg
  local mode_set=0

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --lang=*)
        HELP_LANG="${arg#*=}"
        ;;
      --lang)
        shift
        if [[ $# -eq 0 ]]; then
          err "$(msg err_missing_lang)"
          echo
          print_help
          exit 1
        fi
        HELP_LANG="$1"
        ;;
      --check|--dry-run|--apply|--help|-h|--author|--authour|--license|--lisense|--version|--install-man)
        if [[ "$mode_set" == "0" ]]; then
          MODE="$arg"
          mode_set=1
        else
          err "$(msg err_unknown_option "$arg")"
          echo
          print_help
          exit 1
        fi
        ;;
      *)
        err "$(msg err_unknown_option "$arg")"
        echo
        print_help
        exit 1
        ;;
    esac
    shift
  done
}

print_author() {
  cat <<EOF
${AUTHOR_NAME} <${AUTHOR_EMAIL}>
${AUTHOR_URL}
EOF
}

print_license() {
  echo "${SCRIPT_LICENSE}"
}

print_version() {
  echo "${SCRIPT_VERSION} (${SCRIPT_DATE})"
}

install_man_page() {
  if [[ ! -f "$MANPAGE_SOURCE" ]]; then
    err "Man page source not found: ${MANPAGE_SOURCE}"
    exit 1
  fi

  mkdir -p "$MANPAGE_DIR"
  gzip -c "$MANPAGE_SOURCE" > "$MANPAGE_TARGET"
  if command_exists mandb; then
    mandb -q >/dev/null 2>&1 || true
  fi
  info "Man page installed: ${MANPAGE_TARGET}"
  info "Use: man mariadb_storage_audit"
}

wait_for_menu_return() {
  local key
  if [[ -t 0 && -t 1 ]]; then
    echo
    echo -e "${DIM}Press Enter or Space to return to the menu...${NC}"
    while true; do
      IFS= read -rsn1 key
      case "$key" in
        ''|' ')
          break
          ;;
      esac
    done
  fi
}

print_help_en() {
  cat <<EOF
${REV}${BOLD} NAME ${NC}
    mariadb_storage_audit.sh - Linux system audit and tuning around MariaDB/MySQL

${REV}${BOLD} SYNOPSIS ${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--check${NC}   [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--dry-run${NC} [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--apply${NC}   [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--help${NC}    [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--author${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--authour${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--license${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--lisense${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--version${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--install-man${NC}

${REV}${BOLD} DESCRIPTION ${NC}
    Audits and, if requested, applies Linux system settings useful around a
    MariaDB/MySQL server. The script may read MariaDB information to understand
    the system context, but ${RED}it never changes MariaDB configuration${NC}.

${REV}${BOLD} LANGUAGE ${NC}
    Default language is selected from ${CYAN}LC_ALL${NC}, ${CYAN}LC_MESSAGES${NC}, then ${CYAN}LANG${NC}.
    Supported languages:
    - ${GREEN}fr${NC}: French
    - ${GREEN}en${NC}: English
    - ${GREEN}ru${NC}: Russian
    - ${GREEN}zh${NC}: Chinese
    Force a language with:
    - ${CYAN}--lang fr${NC}
    - ${CYAN}--lang en${NC}
    - ${CYAN}--lang ru${NC}
    - ${CYAN}--lang zh${NC}

${REV}${BOLD} MODES ${NC}
    ${BOLD}${GREEN}--check${NC}
        Read-only audit mode.

    ${BOLD}${GREEN}--dry-run${NC}
        Does not apply changes. Prints the commands and file writes that
        ${BOLD}${GREEN}--apply${NC} would execute.

    ${BOLD}${GREEN}--apply${NC}
        Applies only Linux system settings, then re-reads changed values and
        exits with an error if the expected state is not really in place.

    ${BOLD}${GREEN}--help${NC}
        Shows this detailed help.

    ${BOLD}${GREEN}--author${NC}, ${BOLD}${GREEN}--authour${NC}
        Show author information.

    ${BOLD}${GREEN}--license${NC}, ${BOLD}${GREEN}--lisense${NC}
        Show license information.

    ${BOLD}${GREEN}--version${NC}
        Show script version and release date.

    ${BOLD}${GREEN}--install-man${NC}
        Install the bundled man page for ${CYAN}man mariadb_storage_audit${NC}.

${REV}${BOLD} SYSTEM SCOPE ${NC}
    This script stays ${BOLD}${YELLOW}system only${NC}.
    It may read MariaDB to improve diagnostics, but it does not write MariaDB settings.

${REV}${BOLD} CHECKS ${NC}
    ${BOLD}${CYAN}Datadir / filesystem${NC}
        Checks whether the MariaDB/MySQL datadir is on a filesystem separate from /.

    ${BOLD}${CYAN}Hypervisor / NVMe${NC}
        Detects physical vs virtualized environment.
        Default VM recommendation: ${GREEN}scheduler=none${NC}.

    ${BOLD}${CYAN}THP${NC}
        Checks:
        - THP enabled = never
        - THP defrag = never
        ${DIM}Debian 13 default:${NC}
        - enabled: madvise
        - defrag: madvise
        ${BOLD}Recommended:${NC}
        - enabled: ${GREEN}never${NC}
        - defrag: ${GREEN}never${NC}

    ${BOLD}${CYAN}vm.swappiness = ${SWAPPINESS}${NC}
        ${DIM}Debian 13 default:${NC} 60
        ${BOLD}Recommended:${NC} ${GREEN}${SWAPPINESS}${NC}

    ${BOLD}${CYAN}vm.dirty_ratio = ${DIRTY_RATIO}${NC}
        ${DIM}Debian 13 / Linux default:${NC} usually 20
        ${BOLD}Recommended:${NC} ${GREEN}${DIRTY_RATIO}${NC}

    ${BOLD}${CYAN}vm.dirty_background_ratio = ${DIRTY_BACKGROUND_RATIO}${NC}
        ${DIM}Debian 13 / Linux default:${NC} usually 10
        ${BOLD}Recommended:${NC} ${GREEN}${DIRTY_BACKGROUND_RATIO}${NC}

    ${BOLD}${CYAN}vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}${NC}
        ${DIM}Debian 13 / Linux default:${NC} 100
        ${BOLD}Recommended:${NC} ${GREEN}${VFS_CACHE_PRESSURE}${NC}

    ${BOLD}${CYAN}LimitNOFILE >= ${LIMIT_NOFILE_EXPECTED}${NC}
        ${DIM}Debian 13 systemd default:${NC} 1024:524288
        ${BOLD}Recommended:${NC} ${GREEN}>= ${LIMIT_NOFILE_EXPECTED}${NC}

    ${BOLD}${CYAN}numa_balancing = ${NUMA_BALANCING_EXPECTED}${NC}
        ${DIM}Debian 13 / Linux default:${NC} no single guaranteed value
        ${BOLD}Recommended:${NC} ${GREEN}${NUMA_BALANCING_EXPECTED}${NC}

    ${BOLD}${CYAN}innodb_flush_method = ${INNODB_FLUSH_METHOD_EXPECTED}${NC}
        ${YELLOW}Information only.${NC}

    ${BOLD}${CYAN}I/O scheduler${NC}
        ${DIM}Debian 13 default:${NC} depends on device, driver, virtualization
        ${BOLD}Recommended:${NC}
        - physical NVMe: ${GREEN}none${NC}
        - physical non-NVMe: ${GREEN}mq-deadline${NC}
        - VM: ${GREEN}none${NC}
        If the guest scheduler is already ${GREEN}none${NC} on a VM, the check is
        considered compliant.

    ${BOLD}${CYAN}read_ahead_kb${NC}
        ${DIM}Debian 13 default:${NC} often 128 KiB, device dependent
        ${BOLD}Recommended:${NC}
        - NVMe: ${GREEN}16${NC}
        - non-NVMe: ${GREEN}128${NC}

    ${BOLD}${CYAN}nr_requests = $(suggest_nr_requests)${NC}
        ${DIM}Debian 13 default:${NC} device dependent
        ${BOLD}Recommended:${NC} ${GREEN}$(suggest_nr_requests)${NC}

    ${BOLD}${CYAN}fstab / mount options${NC}
        Proposed values:
        - ext4: ${GREEN}${EXT4_MOUNT_OPTS}${NC}
        - other FS: ${GREEN}${DEFAULT_MOUNT_OPTS}${NC}

${REV}${BOLD} FILES ${NC}
    Files modified by ${BOLD}${GREEN}--apply${NC}:
    ${SYSCTL_FILE}
    ${THP_SERVICE}
    ${UDEV_RULE}
    ${FSTAB_FILE}

${REV}${BOLD} AUTHOR ${NC}
    ${AUTHOR_NAME} <${AUTHOR_EMAIL}>
    ${AUTHOR_URL}

${REV}${BOLD} LICENSE ${NC}
    ${SCRIPT_LICENSE}

${REV}${BOLD} VERSION ${NC}
    ${SCRIPT_VERSION} (${SCRIPT_DATE})
EOF
}

print_help_ru() {
  cat <<EOF
${REV}${BOLD} ИМЯ ${NC}
    mariadb_storage_audit.sh - аудит и системный тюнинг Linux для MariaDB/MySQL

${REV}${BOLD} СИНТАКСИС ${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--check${NC}   [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--dry-run${NC} [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--apply${NC}   [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--help${NC}    [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--author${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--authour${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--license${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--lisense${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--version${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--install-man${NC}

${REV}${BOLD} ОПИСАНИЕ ${NC}
    Скрипт проверяет и, при необходимости, применяет только системные настройки
    Linux вокруг MariaDB/MySQL. Скрипт может читать информацию из MariaDB для
    понимания контекста, но ${RED}никогда не изменяет конфигурацию MariaDB${NC}.

${REV}${BOLD} ЯЗЫК ${NC}
    Язык по умолчанию выбирается из ${CYAN}LC_ALL${NC}, ${CYAN}LC_MESSAGES${NC}, затем ${CYAN}LANG${NC}.
    Поддерживаются:
    - ${GREEN}fr${NC}: французский
    - ${GREEN}en${NC}: английский
    - ${GREEN}ru${NC}: русский
    - ${GREEN}zh${NC}: китайский
    Принудительный выбор:
    - ${CYAN}--lang fr${NC}
    - ${CYAN}--lang en${NC}
    - ${CYAN}--lang ru${NC}
    - ${CYAN}--lang zh${NC}

${REV}${BOLD} РЕЖИМЫ ${NC}
    ${BOLD}${GREEN}--check${NC}
        Только аудит, без изменений.

    ${BOLD}${GREEN}--dry-run${NC}
        Ничего не применяет. Показывает команды и записи в файлы, которые
        выполнил бы режим ${BOLD}${GREEN}--apply${NC}.

    ${BOLD}${GREEN}--apply${NC}
        Применяет только системные настройки Linux, затем перечитывает изменённые
        значения и завершает работу с ошибкой, если итоговое состояние неверно.

    ${BOLD}${GREEN}--help${NC}
        Показывает эту подробную справку.

    ${BOLD}${GREEN}--author${NC}, ${BOLD}${GREEN}--authour${NC}
        Показывает информацию об авторе.

    ${BOLD}${GREEN}--license${NC}, ${BOLD}${GREEN}--lisense${NC}
        Показывает информацию о лицензии.

    ${BOLD}${GREEN}--version${NC}
        Показывает версию скрипта и дату выпуска.

    ${BOLD}${GREEN}--install-man${NC}
        Устанавливает встроенную man-страницу для ${CYAN}man mariadb_storage_audit${NC}.

${REV}${BOLD} СИСТЕМНЫЙ ПЕРИМЕТР ${NC}
    Скрипт работает только в области ${BOLD}${YELLOW}system only${NC}.
    Он может читать MariaDB для диагностики, но не записывает настройки MariaDB.

${REV}${BOLD} ПРОВЕРКИ ${NC}
    ${BOLD}${CYAN}Datadir / filesystem${NC}
        Проверяет, что datadir MariaDB/MySQL находится на файловой системе,
        отдельной от /.

    ${BOLD}${CYAN}Hypervisor / NVMe${NC}
        Определяет физическая это машина или виртуальная.
        Рекомендация по умолчанию для VM: ${GREEN}scheduler=none${NC}.

    ${BOLD}${CYAN}THP${NC}
        Проверки:
        - THP enabled = never
        - THP defrag = never
        ${DIM}Значение Debian 13 по умолчанию:${NC}
        - enabled: madvise
        - defrag: madvise
        ${BOLD}Рекомендуется:${NC}
        - enabled: ${GREEN}never${NC}
        - defrag: ${GREEN}never${NC}

    ${BOLD}${CYAN}vm.swappiness = ${SWAPPINESS}${NC}
        ${DIM}Debian 13 по умолчанию:${NC} 60
        ${BOLD}Рекомендуется:${NC} ${GREEN}${SWAPPINESS}${NC}

    ${BOLD}${CYAN}vm.dirty_ratio = ${DIRTY_RATIO}${NC}
        ${DIM}Debian 13 / Linux по умолчанию:${NC} обычно 20
        ${BOLD}Рекомендуется:${NC} ${GREEN}${DIRTY_RATIO}${NC}

    ${BOLD}${CYAN}vm.dirty_background_ratio = ${DIRTY_BACKGROUND_RATIO}${NC}
        ${DIM}Debian 13 / Linux по умолчанию:${NC} обычно 10
        ${BOLD}Рекомендуется:${NC} ${GREEN}${DIRTY_BACKGROUND_RATIO}${NC}

    ${BOLD}${CYAN}vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}${NC}
        ${DIM}Debian 13 / Linux по умолчанию:${NC} 100
        ${BOLD}Рекомендуется:${NC} ${GREEN}${VFS_CACHE_PRESSURE}${NC}

    ${BOLD}${CYAN}LimitNOFILE >= ${LIMIT_NOFILE_EXPECTED}${NC}
        ${DIM}systemd Debian 13 по умолчанию:${NC} 1024:524288
        ${BOLD}Рекомендуется:${NC} ${GREEN}>= ${LIMIT_NOFILE_EXPECTED}${NC}

    ${BOLD}${CYAN}numa_balancing = ${NUMA_BALANCING_EXPECTED}${NC}
        ${DIM}Debian 13 / Linux по умолчанию:${NC} нет единого гарантированного значения
        ${BOLD}Рекомендуется:${NC} ${GREEN}${NUMA_BALANCING_EXPECTED}${NC}

    ${BOLD}${CYAN}innodb_flush_method = ${INNODB_FLUSH_METHOD_EXPECTED}${NC}
        ${YELLOW}Только информация.${NC}

    ${BOLD}${CYAN}I/O scheduler${NC}
        ${DIM}Debian 13 по умолчанию:${NC} зависит от устройства, драйвера и виртуализации
        ${BOLD}Рекомендуется:${NC}
        - физический NVMe: ${GREEN}none${NC}
        - физический не-NVMe: ${GREEN}mq-deadline${NC}
        - VM: ${GREEN}none${NC}
        Если в виртуальной машине планировщик гостевой ОС уже ${GREEN}none${NC},
        проверка считается успешной.

    ${BOLD}${CYAN}read_ahead_kb${NC}
        ${DIM}Debian 13 по умолчанию:${NC} часто 128 KiB, зависит от устройства
        ${BOLD}Рекомендуется:${NC}
        - NVMe: ${GREEN}16${NC}
        - не-NVMe: ${GREEN}128${NC}

    ${BOLD}${CYAN}nr_requests = $(suggest_nr_requests)${NC}
        ${DIM}Debian 13 по умолчанию:${NC} зависит от устройства
        ${BOLD}Рекомендуется:${NC} ${GREEN}$(suggest_nr_requests)${NC}

    ${BOLD}${CYAN}fstab / mount options${NC}
        Предлагаемые значения:
        - ext4: ${GREEN}${EXT4_MOUNT_OPTS}${NC}
        - другая FS: ${GREEN}${DEFAULT_MOUNT_OPTS}${NC}

${REV}${BOLD} ФАЙЛЫ ${NC}
    Файлы, изменяемые через ${BOLD}${GREEN}--apply${NC}:
    ${SYSCTL_FILE}
    ${THP_SERVICE}
    ${UDEV_RULE}
    ${FSTAB_FILE}

${REV}${BOLD} АВТОР ${NC}
    ${AUTHOR_NAME} <${AUTHOR_EMAIL}>
    ${AUTHOR_URL}

${REV}${BOLD} ЛИЦЕНЗИЯ ${NC}
    ${SCRIPT_LICENSE}

${REV}${BOLD} ВЕРСИЯ ${NC}
    ${SCRIPT_VERSION} (${SCRIPT_DATE})
EOF
}

print_help_zh() {
  cat <<EOF
${REV}${BOLD} 名称 ${NC}
    mariadb_storage_audit.sh - 面向 MariaDB/MySQL 的 Linux 系统审计与调优脚本

${REV}${BOLD} 用法 ${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--check${NC}   [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--dry-run${NC} [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--apply${NC}   [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--help${NC}    [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--author${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--authour${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--license${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--lisense${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--version${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--install-man${NC}

${REV}${BOLD} 说明 ${NC}
    该脚本用于审计并在需要时应用 MariaDB/MySQL 周边的 Linux 系统设置。
    脚本可以读取 MariaDB 信息以便理解系统上下文，但 ${RED}不会修改 MariaDB 配置${NC}。

${REV}${BOLD} 语言 ${NC}
    默认语言按以下顺序自动选择：
    ${CYAN}LC_ALL${NC} -> ${CYAN}LC_MESSAGES${NC} -> ${CYAN}LANG${NC}
    支持语言：
    - ${GREEN}fr${NC}: 法语
    - ${GREEN}en${NC}: 英语
    - ${GREEN}ru${NC}: 俄语
    - ${GREEN}zh${NC}: 中文

${REV}${BOLD} 模式 ${NC}
    ${BOLD}${GREEN}--check${NC}
        只读审计模式。

    ${BOLD}${GREEN}--dry-run${NC}
        不执行任何修改，只显示 ${BOLD}${GREEN}--apply${NC} 将要执行的命令和文件写入。

    ${BOLD}${GREEN}--apply${NC}
        只应用 Linux 系统设置，并在之后重新读取关键值进行校验。

    ${BOLD}${GREEN}--help${NC}
        显示本帮助。

    ${BOLD}${GREEN}--author${NC}, ${BOLD}${GREEN}--authour${NC}
        显示作者信息。

    ${BOLD}${GREEN}--license${NC}, ${BOLD}${GREEN}--lisense${NC}
        显示许可证信息。

    ${BOLD}${GREEN}--version${NC}
        显示脚本版本和发布日期。

    ${BOLD}${GREEN}--install-man${NC}
        安装内置 man 手册页，以便使用 ${CYAN}man mariadb_storage_audit${NC}。

${REV}${BOLD} 系统范围 ${NC}
    本脚本严格限制在 ${BOLD}${YELLOW}system only${NC} 范围内。
    它可以读取 MariaDB 信息做诊断，但不会写入 MariaDB 参数。

${REV}${BOLD} 检查项 ${NC}
    ${BOLD}${CYAN}Datadir / filesystem${NC}
        检查 MariaDB/MySQL 数据目录是否位于独立于 / 的文件系统上。

    ${BOLD}${CYAN}Hypervisor / NVMe${NC}
        检测当前环境是物理机还是虚拟机。
        虚拟机默认建议：${GREEN}scheduler=none${NC}

    ${BOLD}${CYAN}THP${NC}
        检查项：
        - THP enabled = never
        - THP defrag = never
        ${DIM}Debian 13 默认值：${NC}
        - enabled: madvise
        - defrag: madvise
        ${BOLD}推荐值：${NC}
        - enabled: ${GREEN}never${NC}
        - defrag: ${GREEN}never${NC}

    ${BOLD}${CYAN}vm.swappiness = ${SWAPPINESS}${NC}
        ${DIM}Debian 13 默认值：${NC} 60
        ${BOLD}推荐值：${NC} ${GREEN}${SWAPPINESS}${NC}

    ${BOLD}${CYAN}vm.dirty_ratio = ${DIRTY_RATIO}${NC}
        ${DIM}Debian 13 / Linux 默认值：${NC} 通常为 20
        ${BOLD}推荐值：${NC} ${GREEN}${DIRTY_RATIO}${NC}

    ${BOLD}${CYAN}vm.dirty_background_ratio = ${DIRTY_BACKGROUND_RATIO}${NC}
        ${DIM}Debian 13 / Linux 默认值：${NC} 通常为 10
        ${BOLD}推荐值：${NC} ${GREEN}${DIRTY_BACKGROUND_RATIO}${NC}

    ${BOLD}${CYAN}vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}${NC}
        ${DIM}Debian 13 / Linux 默认值：${NC} 100
        ${BOLD}推荐值：${NC} ${GREEN}${VFS_CACHE_PRESSURE}${NC}

    ${BOLD}${CYAN}LimitNOFILE >= ${LIMIT_NOFILE_EXPECTED}${NC}
        ${DIM}Debian 13 systemd 默认值：${NC} 1024:524288
        ${BOLD}推荐值：${NC} ${GREEN}>= ${LIMIT_NOFILE_EXPECTED}${NC}

    ${BOLD}${CYAN}numa_balancing = ${NUMA_BALANCING_EXPECTED}${NC}
        ${DIM}Debian 13 / Linux 默认值：${NC} 没有统一保证值
        ${BOLD}推荐值：${NC} ${GREEN}${NUMA_BALANCING_EXPECTED}${NC}

    ${BOLD}${CYAN}I/O scheduler${NC}
        ${DIM}Debian 13 默认值：${NC} 取决于设备、驱动和虚拟化层
        ${BOLD}推荐值：${NC}
        - 物理 NVMe: ${GREEN}none${NC}
        - 物理非 NVMe: ${GREEN}mq-deadline${NC}
        - VM: ${GREEN}none${NC}

    ${BOLD}${CYAN}read_ahead_kb${NC}
        ${DIM}Debian 13 默认值：${NC} 常见为 128 KiB，但依赖设备
        ${BOLD}推荐值：${NC}
        - NVMe: ${GREEN}16${NC}
        - 非 NVMe: ${GREEN}128${NC}

    ${BOLD}${CYAN}nr_requests = $(suggest_nr_requests)${NC}
        ${DIM}Debian 13 默认值：${NC} 依赖具体设备
        ${BOLD}推荐值：${NC} ${GREEN}$(suggest_nr_requests)${NC}

${REV}${BOLD} 文件 ${NC}
    ${BOLD}${GREEN}--apply${NC} 可能修改的文件：
    ${SYSCTL_FILE}
    ${THP_SERVICE}
    ${UDEV_RULE}
    ${FSTAB_FILE}

${REV}${BOLD} 作者 ${NC}
    ${AUTHOR_NAME} <${AUTHOR_EMAIL}>
    ${AUTHOR_URL}

${REV}${BOLD} 许可证 ${NC}
    ${SCRIPT_LICENSE}

${REV}${BOLD} 版本 ${NC}
    ${SCRIPT_VERSION} (${SCRIPT_DATE})
EOF
}

print_help_body() {
  case "$(detect_help_lang)" in
    fr)
      cat <<EOF
${REV}${BOLD} NOM ${NC}
    mariadb_storage_audit.sh - audit et tuning système Linux autour de MariaDB/MySQL

${REV}${BOLD} SYNOPSIS ${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--check${NC}   [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--dry-run${NC} [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--apply${NC}   [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--help${NC}    [${BOLD}--lang${NC} ${CYAN}fr|en|ru|zh${NC}]
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--author${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--authour${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--license${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--lisense${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--version${NC}
    ${BOLD}${CYAN}$0${NC} ${BOLD}${GREEN}--install-man${NC}

${REV}${BOLD} DESCRIPTION ${NC}
    Audit et, si demandé, applique uniquement des réglages système Linux utiles
    autour d'un serveur MariaDB/MySQL. Le script peut lire des informations
    MariaDB pour contextualiser le système, mais ${RED}ne modifie jamais la
    configuration MariaDB${NC}.

${REV}${BOLD} LANGUE ${NC}
    La langue par défaut est choisie à partir de ${CYAN}LC_ALL${NC}, ${CYAN}LC_MESSAGES${NC}, puis ${CYAN}LANG${NC}.
    Langues supportées :
    - ${GREEN}fr${NC}: français
    - ${GREEN}en${NC}: anglais
    - ${GREEN}ru${NC}: russe
    - ${GREEN}zh${NC}: chinois
    Forcer une langue avec :
    - ${CYAN}--lang fr${NC}
    - ${CYAN}--lang en${NC}
    - ${CYAN}--lang ru${NC}
    - ${CYAN}--lang zh${NC}

${REV}${BOLD} MODES ${NC}
    ${BOLD}${GREEN}--check${NC}
        Audit en lecture seule. Détecte le datadir, le disque, la
        virtualisation, le filesystem, les limites systemd et plusieurs
        réglages noyau. Aucune modification n'est appliquée.

    ${BOLD}${GREEN}--dry-run${NC}
        N'applique rien. Affiche les commandes et écritures de fichiers que
        le mode ${BOLD}${GREEN}--apply${NC} exécuterait.

    ${BOLD}${GREEN}--apply${NC}
        Applique uniquement les réglages système suivants puis relit l'état final:
        - sysctl: vm.swappiness, vm.dirty_ratio, vm.dirty_background_ratio,
          vm.vfs_cache_pressure
        - THP: désactivation immédiate + service systemd persistant
        - scheduler disque: règle udev + réglage runtime
        - paramètres bloc: read_ahead_kb et nr_requests
        - fstab: ajout d'une entrée de montage cible si absente

        Si une valeur attendue n'est pas réellement appliquée après relecture,
        le script sort en erreur avec un message ${RED}rouge${NC}.

    ${BOLD}${GREEN}--help${NC}
        Affiche cette aide détaillée, au format proche d'une page man.

    ${BOLD}${GREEN}--author${NC}, ${BOLD}${GREEN}--authour${NC}
        Affiche les informations d'auteur.

    ${BOLD}${GREEN}--license${NC}, ${BOLD}${GREEN}--lisense${NC}
        Affiche les informations de licence.

    ${BOLD}${GREEN}--version${NC}
        Affiche la version du script et sa date de publication.

    ${BOLD}${GREEN}--install-man${NC}
        Installe la page man fournie pour ${CYAN}man mariadb_storage_audit${NC}.

    Langues supportées:
        ${GREEN}fr${NC}, ${GREEN}en${NC}, ${GREEN}ru${NC}, ${GREEN}zh${NC}

${REV}${BOLD} PÉRIMÈTRE SYSTÈME ${NC}
    Le script reste dans un périmètre ${BOLD}${YELLOW}system only${NC}.
    Il peut lire MariaDB pour mieux comprendre le système, mais il n'écrit pas
    dans la configuration MariaDB.

${REV}${BOLD} VÉRIFICATIONS ${NC}
    ${BOLD}${CYAN}Datadir / filesystem${NC}
        Vérifie que le datadir MariaDB/MySQL est sur un filesystem séparé de /.
        But: isoler les IO et permettre des options de montage adaptées.

    ${BOLD}${CYAN}Hyperviseur / NVMe${NC}
        Détecte si la machine est physique ou virtualisée.
        Cas d'usage:
        - physique: le scheduler guest est généralement significatif
        - VM VMware/Proxmox/KVM: le backend hyperviseur pèse souvent plus lourd
          que le scheduler exposé dans l'invité
        En VM, la recommandation par défaut du script est ${GREEN}scheduler=none${NC}.

    ${BOLD}${CYAN}THP${NC}
        Checks:
        - THP enabled = never
        - THP defrag = never
        ${DIM}Défaut Debian 13 / noyau Linux actuel:${NC}
        - enabled: madvise
        - defrag: madvise
        ${BOLD}Recommandé pour MariaDB:${NC}
        - enabled: ${GREEN}never${NC}
        - defrag: ${GREEN}never${NC}
        Pourquoi:
        Transparent Huge Pages peut introduire de la latence et des pauses de
        compaction peu désirables pour une base OLTP.

    ${BOLD}${CYAN}vm.swappiness = ${SWAPPINESS}${NC}
        ${DIM}Défaut Debian 13:${NC} 60
        ${BOLD}Recommandé:${NC} ${GREEN}${SWAPPINESS}${NC}
        Pourquoi:
        Réduit la propension du noyau à swapper des pages mémoire anonymes.
        Cas d'usage:
        - serveur MariaDB dédié: bas
        - serveur mixte: éventuellement un peu plus haut

    ${BOLD}${CYAN}vm.dirty_ratio = ${DIRTY_RATIO}${NC}
        ${DIM}Défaut Debian 13 / Linux:${NC} généralement 20
        ${BOLD}Recommandé:${NC} ${GREEN}${DIRTY_RATIO}${NC}
        Pourquoi:
        Limite l'accumulation de mémoire sale avant flush forcé.

    ${BOLD}${CYAN}vm.dirty_background_ratio = ${DIRTY_BACKGROUND_RATIO}${NC}
        ${DIM}Défaut Debian 13 / Linux:${NC} généralement 10
        ${BOLD}Recommandé:${NC} ${GREEN}${DIRTY_BACKGROUND_RATIO}${NC}
        Pourquoi:
        Déclenche plus tôt le writeback en arrière-plan.

    ${BOLD}${CYAN}vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}${NC}
        ${DIM}Défaut Debian 13 / Linux:${NC} 100
        ${BOLD}Recommandé:${NC} ${GREEN}${VFS_CACHE_PRESSURE}${NC}
        Pourquoi:
        Favorise une conservation plus raisonnable des métadonnées VFS.

    ${BOLD}${CYAN}LimitNOFILE >= ${LIMIT_NOFILE_EXPECTED}${NC}
        ${DIM}Défaut systemd Debian 13:${NC} 1024:524288
        ${BOLD}Recommandé pour le service MariaDB:${NC} ${GREEN}>= ${LIMIT_NOFILE_EXPECTED}${NC}
        Pourquoi:
        Évite une limite de descripteurs trop basse côté systemd.
        Lecture:
        - compare la limite systemd
        - peut aussi lire la valeur exposée à MariaDB pour diagnostic

    ${BOLD}${CYAN}numa_balancing = ${NUMA_BALANCING_EXPECTED}${NC}
        ${DIM}Défaut Debian 13 / Linux:${NC}
        - pas de valeur unique garantie
        - souvent activé (=1) quand la fonctionnalité est présente
        ${BOLD}Recommandé:${NC} ${GREEN}${NUMA_BALANCING_EXPECTED}${NC}
        Pourquoi:
        Réduit le bruit lié aux migrations automatiques de pages mémoire.

    ${BOLD}${CYAN}innodb_flush_method = ${INNODB_FLUSH_METHOD_EXPECTED}${NC}
        ${YELLOW}Information seulement.${NC}
        Ce n'est pas un réglage système, mais un indicateur utile du chemin IO
        actuellement utilisé par MariaDB.

    ${BOLD}${CYAN}Scheduler disque${NC}
        ${DIM}Défaut Debian 13:${NC}
        - pas de valeur unique
        - dépend du device, du driver bloc et de la virtualisation
        ${BOLD}Recommandé:${NC}
        - physique NVMe: ${GREEN}none${NC}
        - physique non-NVMe: ${GREEN}mq-deadline${NC}
        - VM: ${GREEN}none${NC} par défaut
        Pourquoi:
        Influence l'ordonnancement IO vu par Linux.
        Important:
        En VM, si le scheduler invité est déjà ${GREEN}none${NC}, le check est
        considéré comme conforme.

    ${BOLD}${CYAN}read_ahead_kb = $(suggest_readahead_kb)${NC}
        ${DIM}Défaut Debian 13:${NC}
        - souvent 128 KiB, mais dépend du device et du driver
        ${BOLD}Recommandé:${NC}
        - NVMe: ${GREEN}16${NC}
        - non-NVMe: ${GREEN}128${NC}
        Pourquoi:
        Évite un read-ahead trop élevé sur une base OLTP.

    ${BOLD}${CYAN}nr_requests = $(suggest_nr_requests)${NC}
        ${DIM}Défaut Debian 13:${NC}
        - pas de valeur unique garantie
        - dépend du driver bloc et du périphérique
        ${BOLD}Recommandé:${NC} ${GREEN}$(suggest_nr_requests)${NC}
        Pourquoi:
        Contrôle la profondeur de file de requêtes côté bloc.

    ${BOLD}${CYAN}fstab / options de montage${NC}
        But:
        Avoir un FS séparé et des options adaptées aux données MariaDB.
        ${BOLD}Valeurs proposées:${NC}
        - ext4: ${GREEN}${EXT4_MOUNT_OPTS}${NC}
        - autre FS: ${GREEN}${DEFAULT_MOUNT_OPTS}${NC}
        Important:
        Le script n'impose pas que le datadir soit déjà sur ${TARGET_MOUNT};
        il vérifie surtout la séparation du FS et sait proposer une ligne fstab.

${REV}${BOLD} FICHIERS ${NC}
    Fichiers modifiés par ${BOLD}${GREEN}--apply${NC}:
    ${SYSCTL_FILE}
    ${THP_SERVICE}
    ${UDEV_RULE}
    ${FSTAB_FILE}

${REV}${BOLD} AUTEUR ${NC}
    ${AUTHOR_NAME} <${AUTHOR_EMAIL}>
    ${AUTHOR_URL}

${REV}${BOLD} LICENCE ${NC}
    ${SCRIPT_LICENSE}

${REV}${BOLD} VERSION ${NC}
    ${SCRIPT_VERSION} (${SCRIPT_DATE})

${REV}${BOLD} VARIABLES ${NC}
    TARGET_DEVICE=${TARGET_DEVICE}
        Partition cible que le script sait auditer/proposer.

    TARGET_MOUNT=${TARGET_MOUNT}
        Point de montage cible proposé pour un volume dédié MariaDB.

${REV}${BOLD} LIMITES ${NC}
    - ne déplace pas automatiquement le datadir
    - ne modifie pas la configuration MariaDB
    - privilégie les réglages système stables et explicables
    - essaye d'être portable GNU/Linux, mais certaines interfaces noyau/systemd
      varient selon distribution, noyau ou hyperviseur
EOF
      ;;
    ru)
      print_help_ru
      ;;
    zh)
      print_help_zh
      ;;
    *)
      print_help_en
      ;;
  esac
}

print_help() {
  if [[ -t 0 && -t 1 ]] && command_exists less; then
    LESS="${LESS:-FRX}" print_help_body | less -R
  else
    print_help_body
  fi
}

mysql_query() {
  local query="$1"
  cache_get "mysql_query:${query}" _mysql_query_uncached "$query"
}

_mysql_query_uncached() {
  mysql --batch --skip-column-names -e "$1" 2>/dev/null || true
}

mysql_single_value() {
  local query="$1"
  mysql_query "$query" | awk 'NF {print $NF}' | tail -n1
}

detect_mariadb_datadir() {
  cache_get "detect_mariadb_datadir" _detect_mariadb_datadir_uncached
}

_detect_mariadb_datadir_uncached() {
  local datadir=""
  if systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
    datadir="$(mysql_query "SHOW VARIABLES LIKE 'datadir';" | awk '{print $2}' | tail -n1)"
  fi

  if [[ -z "$datadir" ]]; then
    if [[ -f /etc/mysql/mariadb.conf.d/50-server.cnf ]]; then
      datadir="$(grep -E '^[[:space:]]*datadir[[:space:]]*=' /etc/mysql/mariadb.conf.d/50-server.cnf | tail -n1 | awk -F= '{print $2}' | xargs || true)"
    fi
  fi

  if [[ -z "$datadir" && -d /var/lib/mysql ]]; then
    datadir="/var/lib/mysql"
  fi

  echo "${datadir%/}"
}

detect_service_name() {
  cache_get "detect_service_name" _detect_service_name_uncached
}

_detect_service_name_uncached() {
  if systemctl list-unit-files | grep -q '^mariadb\.service'; then
    echo "mariadb"
    return
  fi
  if systemctl list-unit-files | grep -q '^mysql\.service'; then
    echo "mysql"
    return
  fi
  echo "mariadb"
}

get_mountpoint_of_path() {
  local path="$1"
  cache_get "mountpoint:${path}" _get_mountpoint_of_path_uncached "$path"
}

_get_mountpoint_of_path_uncached() {
  findmnt -no TARGET --target "$1" 2>/dev/null || echo "UNKNOWN"
}

get_source_of_path() {
  local path="$1"
  cache_get "mountsource:${path}" _get_source_of_path_uncached "$path"
}

_get_source_of_path_uncached() {
  findmnt -no SOURCE --target "$1" 2>/dev/null || echo "UNKNOWN"
}

get_fstype_of_path() {
  local path="$1"
  cache_get "mountfstype:${path}" _get_fstype_of_path_uncached "$path"
}

_get_fstype_of_path_uncached() {
  findmnt -no FSTYPE --target "$1" 2>/dev/null || echo "UNKNOWN"
}

get_usage_of_mount() {
  local mount="$1"
  df -hP "$mount" 2>/dev/null | awk 'NR==2 {print $2 " total / " $3 " used / " $4 " free / " $5 " used"}' || true
}

get_uuid() {
  local device="$1"
  cache_get "uuid:${device}" _get_uuid_uncached "$device"
}

_get_uuid_uncached() {
  blkid -s UUID -o value "$1" 2>/dev/null || true
}

get_fstype_device() {
  local device="$1"
  cache_get "fstype_device:${device}" _get_fstype_device_uncached "$device"
}

_get_fstype_device_uncached() {
  blkid -s TYPE -o value "$1" 2>/dev/null || true
}

get_parent_disk() {
  cache_get "parent_disk:${TARGET_DEVICE}" _get_parent_disk_uncached "$TARGET_DEVICE"
}

_get_parent_disk_uncached() {
  lsblk -no PKNAME "$1" 2>/dev/null || true
}

get_disk_path() {
  local parent
  parent="$(get_parent_disk)"
  if [[ -n "$parent" ]]; then
    echo "/dev/$parent"
  else
    echo "$TARGET_DEVICE"
  fi
}

get_disk_name() {
  basename "$(get_disk_path)"
}

get_datadir_mount_source() {
  local datadir
  datadir="$(detect_mariadb_datadir)"
  get_source_of_path "$datadir"
}

get_parent_disk_for_path() {
  local source="$1"
  local pkname

  case "$source" in
    /dev/*)
      pkname="$(cache_get "parent_disk:${source}" _get_parent_disk_uncached "$source")"
      if [[ -n "$pkname" ]]; then
        echo "/dev/$pkname"
      else
        echo "$source"
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

get_datadir_disk_path() {
  local source
  source="$(get_datadir_mount_source)"
  get_parent_disk_for_path "$source"
}

is_datadir_on_nvme() {
  local disk
  disk="$(get_datadir_disk_path)"
  [[ -n "$disk" && "$(basename "$disk")" == nvme* ]]
}

get_virtualization_raw() {
  cache_get "virt_raw" _get_virtualization_raw_uncached
}

get_hardware_vendor() {
  cache_get "hardware_vendor" _get_hardware_vendor_uncached
}

_get_virtualization_raw_uncached() {
  systemd-detect-virt 2>/dev/null || true
}

_get_hardware_vendor_uncached() {
  hostnamectl status 2>/dev/null | awk -F: '/Hardware Vendor/ {gsub(/^[[:space:]]+/, "", $2); print $2}' | head -n1
}

detect_virtualization_type() {
  local virt vendor

  virt="$(get_virtualization_raw)"
  vendor="$(get_hardware_vendor)"

  case "$virt" in
    vmware)
      echo "VMware"
      ;;
    kvm|qemu)
      if [[ "$vendor" == "QEMU" ]]; then
        echo "Proxmox/KVM"
      else
        echo "KVM"
      fi
      ;;
    microsoft)
      echo "Hyper-V"
      ;;
    oracle)
      echo "VirtualBox"
      ;;
    "")
      echo "Physique"
      ;;
    *)
      echo "$virt"
      ;;
  esac
}

is_virtualized_host() {
  local virt
  virt="$(get_virtualization_raw)"
  [[ -n "$virt" && "$virt" != "none" ]]
}

get_scheduler_file() {
  echo "/sys/block/$(get_disk_name)/queue/scheduler"
}

get_ra_file() {
  echo "/sys/block/$(get_disk_name)/queue/read_ahead_kb"
}

get_nr_requests_file() {
  echo "/sys/block/$(get_disk_name)/queue/nr_requests"
}

get_numa_balancing_file() {
  echo "/proc/sys/kernel/numa_balancing"
}

get_scheduler_current() {
  local f
  f="$(get_scheduler_file)"
  [[ -f "$f" ]] && cache_get "file:${f}" read_file_uncached "$f" || echo "N/A"
}

choose_scheduler() {
  if is_virtualized_host; then
    echo "none"
    return
  fi

  local disk
  disk="$(get_disk_name)"
  if [[ "$disk" == nvme* ]]; then
    echo "none"
  else
    echo "mq-deadline"
  fi
}

suggest_readahead_kb() {
  local disk
  disk="$(get_disk_name)"
  if [[ "$disk" == nvme* ]]; then
    echo "16"
  else
    echo "128"
  fi
}

suggest_nr_requests() {
  if is_virtualized_host; then
    echo "256"
  else
    echo "$NR_REQUESTS_DEFAULT"
  fi
}

get_mount_opts_for_device() {
  local fs
  fs="$(get_fstype_device "$TARGET_DEVICE")"

  case "$fs" in
    ext4)
      echo "$EXT4_MOUNT_OPTS"
      ;;
    *)
      echo "$DEFAULT_MOUNT_OPTS"
      ;;
  esac
}

expected_mount_opts() {
  get_mount_opts_for_device
}

fstab_line_for_target() {
  local uuid fs opts
  uuid="$(get_uuid "$TARGET_DEVICE")"
  fs="$(get_fstype_device "$TARGET_DEVICE")"
  [[ -z "$fs" ]] && fs="$DEFAULT_FS_TYPE"
  opts="$(get_mount_opts_for_device)"
  echo "UUID=${uuid} ${TARGET_MOUNT} ${fs} ${opts} 0 2"
}

target_mount_regex() {
  printf '%s\n' "(${TARGET_MOUNT}|${ALT_TARGET_MOUNT})"
}

get_target_fstab_line() {
  grep -E "^[^#].*[[:space:]]$(target_mount_regex)[[:space:]]" "$FSTAB_FILE" 2>/dev/null | head -n1 || true
}

get_target_mounted_path() {
  if findmnt -no TARGET "$TARGET_MOUNT" >/dev/null 2>&1; then
    echo "$TARGET_MOUNT"
  elif findmnt -no TARGET "$ALT_TARGET_MOUNT" >/dev/null 2>&1; then
    echo "$ALT_TARGET_MOUNT"
  else
    echo ""
  fi
}

has_fstab_entry_for_mount() {
  [[ -n "$(get_target_fstab_line)" ]]
}

status_line() {
  local state="$1"
  local label="$2"
  local current="${3:-}"
  local padded_label

  padded_label="$(pad_label "$label" "$STATUS_LABEL_WIDTH")"

  case "$state" in
    1)
      if [[ -n "$current" ]]; then
        printf "${GREEN}[OK]${NC} %s %s\n" "$padded_label" "$current"
      else
        printf "${GREEN}[OK]${NC} %s\n" "$label"
      fi
      ;;
    -)
      if [[ -n "$current" ]]; then
        printf "${CYAN}[--]${NC} %s %s\n" "$padded_label" "$current"
      else
        printf "${CYAN}[--]${NC} %s\n" "$label"
      fi
      ;;
    *)
      if [[ -n "$current" ]]; then
        printf "${RED}[!!]${NC} %s %s\n" "$padded_label" "$current"
      else
        printf "${RED}[!!]${NC} %s\n" "$label"
      fi
      ;;
  esac
}

pad_label() {
  local text="$1"
  local width="$2"
  awk -v s="$text" -v w="$width" 'BEGIN { printf "%-*s", w, s }'
}

extract_selected_bracket_value() {
  local raw="$1"
  if [[ "$raw" =~ \[([^\]]+)\] ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

normalize_numeric_value() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$raw"
  fi
}

is_thp_disabled() {
  local thp
  thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
  [[ "$thp" == *"[never]"* ]]
}

is_thp_enabled_never() {
  [[ "$(extract_selected_bracket_value "$(current_thp_enabled_value)")" == "never" ]]
}

is_thp_defrag_never() {
  [[ "$(extract_selected_bracket_value "$(current_thp_defrag_value)")" == "never" ]]
}

is_value_equal() {
  local file="$1"
  local expected="$2"
  local v
  v="$(cat "$file" 2>/dev/null || true)"
  [[ "$v" == "$expected" ]]
}

is_scheduler_ok() {
  local current expected
  current="$(extract_selected_bracket_value "$(get_scheduler_current)")"
  expected="$(choose_scheduler)"
  [[ "$current" == "$expected" ]]
}

is_readahead_ok() {
  local file expected
  file="$(get_ra_file)"
  expected="$(suggest_readahead_kb)"
  [[ -f "$file" ]] || return 1
  [[ "$(cat "$file" 2>/dev/null)" == "$expected" ]]
}

is_nr_requests_ok() {
  local file
  file="$(get_nr_requests_file)"
  [[ -f "$file" ]] || return 1
  [[ "$(cat "$file" 2>/dev/null)" == "$(suggest_nr_requests)" ]]
}

is_mariadb_active() {
  systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null
}

is_datadir_detected() {
  local datadir
  datadir="$(detect_mariadb_datadir)"
  [[ -n "$datadir" && -d "$datadir" ]]
}

is_mountpoint_identified() {
  local datadir mount
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  [[ -n "$mount" && "$mount" != "UNKNOWN" ]]
}

is_datadir_on_separate_fs_from_root() {
  local datadir mount root_mount
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  root_mount="$(get_mountpoint_of_path /)"
  [[ -n "$mount" && "$mount" != "UNKNOWN" && "$mount" != "$root_mount" ]]
}

is_target_device_present() {
  [[ -b "$TARGET_DEVICE" ]]
}

is_target_uuid_present() {
  [[ -n "$(get_uuid "$TARGET_DEVICE")" ]]
}

is_target_fs_present() {
  [[ -n "$(get_fstype_device "$TARGET_DEVICE")" ]]
}

is_target_fstab_present() {
  [[ -n "$(get_target_fstab_line)" ]]
}

is_target_fstab_optimized() {
  local expected line
  expected="$(expected_mount_opts)"
  line="$(get_target_fstab_line)"
  [[ -n "$line" && "$line" == *"$expected"* ]]
}

is_target_mounted() {
  [[ -n "$(get_target_mounted_path)" ]]
}

is_datadir_mount_in_fstab() {
  local datadir mount
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  [[ -n "$mount" && "$mount" != "UNKNOWN" ]] || return 1
  grep -Eq "^[^#].*[[:space:]]${mount}[[:space:]]" "$FSTAB_FILE"
}

is_datadir_mount_optimized_in_fstab() {
  local datadir mount line
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  [[ -n "$mount" && "$mount" != "UNKNOWN" ]] || return 1
  line="$(grep -E "^[^#].*[[:space:]]${mount}[[:space:]]" "$FSTAB_FILE" 2>/dev/null | head -n1 || true)"
  [[ -n "$line" && "$line" == *"noatime"* ]]
}

is_datadir_mount_mounted() {
  local datadir mount source
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  source="$(get_source_of_path "$datadir")"
  [[ -n "$mount" && "$mount" != "UNKNOWN" && -n "$source" && "$source" != "UNKNOWN" && "$source" != "overlay" ]]
}

get_systemd_limit_nofile() {
  local service
  service="$(detect_service_name)"
  cache_get "systemd_limit_nofile:${service}" _get_systemd_limit_nofile_uncached "$service"
}

_get_systemd_limit_nofile_uncached() {
  systemctl show "$1" -p LimitNOFILE 2>/dev/null | awk -F= 'NR==1 {print $2}' || true
}

get_mysql_open_files_limit() {
  mysql_single_value "SHOW VARIABLES LIKE 'open_files_limit';"
}

get_innodb_flush_method_value() {
  local value
  value="$(mysql_single_value "SHOW VARIABLES LIKE 'innodb_flush_method';")"
  if [[ -n "$value" ]]; then
    echo "$value"
    return
  fi

  value="$(
    grep -RhsE '^[[:space:]]*innodb_flush_method[[:space:]]*=' /etc/mysql/my.cnf /etc/mysql/mariadb.cnf /etc/mysql/conf.d /etc/mysql/mariadb.conf.d 2>/dev/null \
      | tail -n1 \
      | awk -F= '{print $2}' \
      | xargs || true
  )"
  echo "$value"
}

path_exists() {
  [[ -e "$1" ]]
}

current_mariadb_service_value() {
  if systemctl is-active --quiet mariadb 2>/dev/null; then
    echo "mariadb=active"
  elif systemctl is-active --quiet mysql 2>/dev/null; then
    echo "mysql=active"
  else
    echo "mariadb/mysql inactive"
  fi
}

current_datadir_value() {
  local datadir
  datadir="$(detect_mariadb_datadir)"
  echo "${datadir:-N/A}"
}

current_datadir_fs_value() {
  local datadir mount root_mount fs
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  root_mount="$(get_mountpoint_of_path /)"
  fs="$(get_fstype_of_path "$datadir")"
  echo "mount=${mount:-N/A} fs=${fs:-N/A} root=${root_mount:-N/A}"
}

current_mountpoint_value() {
  local datadir mount
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  echo "${mount:-N/A}"
}

current_target_device_value() {
  if [[ -b "$TARGET_DEVICE" ]]; then
    echo "$TARGET_DEVICE"
  else
    echo "absent ($TARGET_DEVICE)"
  fi
}

current_target_uuid_value() {
  local uuid
  uuid="$(get_uuid "$TARGET_DEVICE")"
  echo "${uuid:-N/A}"
}

current_target_fs_value() {
  local fs
  fs="$(get_fstype_device "$TARGET_DEVICE")"
  echo "${fs:-N/A}"
}

current_target_fstab_value() {
  local line
  line="$(get_target_fstab_line)"
  echo "${line:-Aucune entrée}"
}

current_target_mount_opts_value() {
  local expected line opts
  expected="$(expected_mount_opts)"
  line="$(get_target_fstab_line)"
  if [[ -z "$line" ]]; then
    echo "attendu=${expected} actuel=Aucune entrée"
    return
  fi

  opts="$(awk '{print $4}' <<< "$line")"
  echo "attendu=${expected} actuel=${opts:-N/A}"
}

current_target_mount_value() {
  local mount
  mount="$(get_target_mounted_path)"
  echo "${mount:-non monté}"
}

current_datadir_mount_fstab_value() {
  local datadir mount line
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  if [[ -z "$mount" || "$mount" == "UNKNOWN" ]]; then
    echo "mount=N/A"
    return
  fi

  line="$(grep -E "^[^#].*[[:space:]]${mount}[[:space:]]" "$FSTAB_FILE" 2>/dev/null | head -n1 || true)"
  if [[ -n "$line" ]]; then
    echo "$line"
  else
    echo "mount=${mount} aucune entrée"
  fi
}

current_datadir_mount_opts_value() {
  local datadir mount line opts
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  if [[ -z "$mount" || "$mount" == "UNKNOWN" ]]; then
    echo "mount=N/A"
    return
  fi

  line="$(grep -E "^[^#].*[[:space:]]${mount}[[:space:]]" "$FSTAB_FILE" 2>/dev/null | head -n1 || true)"
  if [[ -z "$line" ]]; then
    echo "mount=${mount} opts=Aucune entrée"
    return
  fi

  opts="$(awk '{print $4}' <<< "$line")"
  echo "mount=${mount} opts=${opts:-N/A}"
}

current_datadir_mount_runtime_value() {
  local datadir mount source
  datadir="$(detect_mariadb_datadir)"
  mount="$(get_mountpoint_of_path "$datadir")"
  source="$(get_source_of_path "$datadir")"
  echo "mount=${mount:-N/A} source=${source:-N/A}"
}

current_limit_nofile_value() {
  local systemd_limit mysql_limit
  systemd_limit="$(get_systemd_limit_nofile)"
  mysql_limit="$(get_mysql_open_files_limit)"
  echo "systemd=${systemd_limit:-N/A} mysql=${mysql_limit:-N/A}"
}

current_numa_balancing_value() {
  local value
  value="$(cat "$(get_numa_balancing_file)" 2>/dev/null || true)"
  echo "${value:-N/A}"
}

current_innodb_flush_method_value() {
  local value
  value="$(get_innodb_flush_method_value)"
  echo "${value:-N/A}"
}

current_thp_value() {
  local enabled defrag
  enabled="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
  defrag="$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true)"

  if [[ -z "$enabled" && -z "$defrag" ]]; then
    echo "N/A"
    return
  fi

  echo "enabled=${enabled:-N/A} defrag=${defrag:-N/A}"
}

current_thp_enabled_value() {
  current_sysctl_value /sys/kernel/mm/transparent_hugepage/enabled
}

current_thp_defrag_value() {
  current_sysctl_value /sys/kernel/mm/transparent_hugepage/defrag
}

current_sysctl_value() {
  local file="$1"
  local value
  value="$(cache_get "file:${file}" read_file_uncached "$file")"
  echo "${value:-N/A}"
}

current_datadir_disk_value() {
  local datadir source disk
  datadir="$(detect_mariadb_datadir)"
  source="$(get_datadir_mount_source)"
  disk="$(get_datadir_disk_path)"
  echo "datadir=${datadir:-N/A} source=${source:-N/A} disk=${disk:-N/A}"
}

current_virtualization_value() {
  local virt vendor
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  vendor="$(hostnamectl status 2>/dev/null | awk -F: '/Hardware Vendor/ {gsub(/^[[:space:]]+/, "", $2); print $2}' | head -n1)"
  echo "type=$(detect_virtualization_type) raw=${virt:-none} vendor=${vendor:-N/A}"
}

current_scheduler_value() {
  if is_virtualized_host; then
    echo "invité=$(get_scheduler_current)"
  else
    echo "$(get_scheduler_current)"
  fi
}

current_readahead_value() {
  current_sysctl_value "$(get_ra_file)"
}

current_nr_requests_value() {
  current_sysctl_value "$(get_nr_requests_file)"
}

scheduler_expectation_label() {
  if is_virtualized_host; then
    echo "none (VM)"
  else
    echo "$(choose_scheduler)"
  fi
}

status_for_datadir_detected() {
  is_datadir_detected && echo "1" || echo "0"
}

status_for_datadir_separate_fs() {
  if ! is_datadir_detected; then
    echo "-"
  elif is_datadir_on_separate_fs_from_root; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_mountpoint_identified() {
  if ! is_datadir_detected; then
    echo "-"
  elif is_mountpoint_identified; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_target_uuid_present() {
  if ! is_target_device_present; then
    echo "-"
  elif is_target_uuid_present; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_target_fs_present() {
  if ! is_target_device_present; then
    echo "-"
  elif is_target_fs_present; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_target_fstab_present() {
  if ! is_target_device_present; then
    echo "-"
  elif is_target_fstab_present; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_target_fstab_optimized() {
  if ! is_target_fstab_present; then
    echo "-"
  elif is_target_fstab_optimized; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_datadir_mount_in_fstab() {
  if ! is_datadir_detected; then
    echo "-"
  elif is_datadir_mount_in_fstab; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_datadir_mount_optimized_in_fstab() {
  if ! is_datadir_mount_in_fstab; then
    echo "-"
  elif is_datadir_mount_optimized_in_fstab; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_datadir_mount_mounted() {
  if ! is_datadir_detected; then
    echo "-"
  elif is_datadir_mount_mounted; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_thp_disabled() {
  if [[ ! -e /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo "-"
  elif is_thp_disabled; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_thp_enabled_never() {
  if [[ ! -e /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo "-"
  elif is_thp_enabled_never; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_thp_defrag_never() {
  if [[ ! -e /sys/kernel/mm/transparent_hugepage/defrag ]]; then
    echo "-"
  elif is_thp_defrag_never; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_value_equal() {
  local file="$1"
  local expected="$2"
  local current
  if ! path_exists "$file"; then
    echo "-"
  else
    current="$(normalize_numeric_value "$(current_sysctl_value "$file")")"
    if [[ -n "$current" && "$current" == "$expected" ]]; then
      echo "1"
    else
      echo "0"
    fi
  fi
}

status_for_scheduler_ok() {
  if [[ ! -f "$(get_scheduler_file)" ]]; then
    echo "-"
  elif is_scheduler_ok; then
    echo "1"
  else
    echo "0"
  fi
}

status_for_readahead_ok() {
  local current
  if [[ ! -f "$(get_ra_file)" ]]; then
    echo "-"
  else
    current="$(normalize_numeric_value "$(current_sysctl_value "$(get_ra_file)")")"
    if [[ -n "$current" && "$current" == "$(suggest_readahead_kb)" ]]; then
      echo "1"
    else
      echo "0"
    fi
  fi
}

status_for_nr_requests_ok() {
  local current
  if [[ ! -f "$(get_nr_requests_file)" ]]; then
    echo "-"
  else
    current="$(normalize_numeric_value "$(current_sysctl_value "$(get_nr_requests_file)")")"
    if [[ -n "$current" && "$current" == "$(suggest_nr_requests)" ]]; then
      echo "1"
    else
      echo "0"
    fi
  fi
}

status_for_limit_nofile_ok() {
  local value
  value="$(normalize_numeric_value "$(get_systemd_limit_nofile)")"
  if [[ -z "$value" ]]; then
    echo "-"
  elif (( value >= LIMIT_NOFILE_EXPECTED )); then
    echo "1"
  else
    echo "0"
  fi
}

status_for_numa_balancing_ok() {
  status_for_value_equal "$(get_numa_balancing_file)" "$NUMA_BALANCING_EXPECTED"
}

status_for_innodb_flush_method_ok() {
  local value
  value="$(get_innodb_flush_method_value)"
  if [[ -z "$value" ]]; then
    echo "-"
  elif [[ "$value" == "$INNODB_FLUSH_METHOD_EXPECTED" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

print_host_resources() {
  kv_line "$(msg cpu_load)" "$(uptime | sed 's/^.*load average: //')"
  echo -e "${BOLD}${CYAN}$(printf '%-22s' "$(msg memory)")${NC} :"
  free -h
  echo
  echo -e "${BOLD}${CYAN}$(printf '%-22s' "$(msg swap_devices)")${NC} :"
  swapon --show || true
  echo
  echo -e "${BOLD}${CYAN}$(printf '%-22s' "$(msg disks)")${NC} :"
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE
}

print_datadir_diagnostics() {
  local datadir current_mount current_source current_fs usage
  datadir="$(detect_mariadb_datadir)"
  current_mount="$(get_mountpoint_of_path "$datadir")"
  current_source="$(get_source_of_path "$datadir")"
  current_fs="$(get_fstype_of_path "$datadir")"
  usage="$(get_usage_of_mount "$current_mount")"

  kv_line "$(msg datadir_mariadb)" "$datadir"
  kv_line "$(msg mountpoint)" "$current_mount"
  kv_line "$(msg source)" "$current_source"
  kv_line "$(msg filesystem)" "$current_fs"
  kv_line "$(msg usage)" "${usage:-N/A}"
}

print_tuning_status() {
  kv_line "vm.swappiness" "$(cat /proc/sys/vm/swappiness)"
  kv_line "vm.dirty_ratio" "$(cat /proc/sys/vm/dirty_ratio)"
  kv_line "vm.dirty_background" "$(cat /proc/sys/vm/dirty_background_ratio)"
  kv_line "vm.vfs_cache_pressure" "$(cat /proc/sys/vm/vfs_cache_pressure)"
  kv_line "THP enabled" "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
  kv_line "THP defrag" "$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo N/A)"
  kv_line "Scheduler" "$(get_scheduler_current)"
  [[ -f "$(get_ra_file)" ]] && kv_line "read_ahead_kb" "$(cat "$(get_ra_file)")"
  [[ -f "$(get_nr_requests_file)" ]] && kv_line "nr_requests" "$(cat "$(get_nr_requests_file)")"
}

print_checklist_before() {
  step "$(msg checklist_before)"

  status_line "$(is_mariadb_active && echo 1 || echo 0)" "$(msg label_service_active)" "$(current_mariadb_service_value)"
  status_line "$(status_for_datadir_detected)" "$(msg label_datadir_detected)" "$(current_datadir_value)"
  status_line "$(status_for_datadir_separate_fs)" "$(msg label_datadir_separate_fs)" "$(current_datadir_fs_value)"
  status_line "$(status_for_mountpoint_identified)" "$(msg label_mountpoint_identified)" "$(current_mountpoint_value)"
  status_line "$(is_target_device_present && echo 1 || echo 0)" "$(msg label_target_device_present)" "$(current_target_device_value)"
  status_line "$(status_for_target_uuid_present)" "$(msg label_target_uuid_present)" "$(current_target_uuid_value)"
  status_line "$(status_for_target_fs_present)" "$(msg label_target_fs_present)" "$(current_target_fs_value)"
  status_line "$(status_for_datadir_mount_in_fstab)" "$(msg label_datadir_fstab_present)" "$(current_datadir_mount_fstab_value)"
  status_line "$(status_for_datadir_mount_optimized_in_fstab)" "$(msg label_datadir_fstab_opts)" "$(current_datadir_mount_opts_value)"
  status_line "$(status_for_datadir_mount_mounted)" "$(msg label_datadir_mounted)" "$(current_datadir_mount_runtime_value)"
  status_line "$(status_for_thp_enabled_never)" "THP enabled = never" "$(current_thp_enabled_value)"
  status_line "$(status_for_thp_defrag_never)" "THP defrag = never" "$(current_thp_defrag_value)"
  status_line "$(status_for_value_equal /proc/sys/vm/swappiness "$SWAPPINESS")" "vm.swappiness = $SWAPPINESS" "$(current_sysctl_value /proc/sys/vm/swappiness)"
  status_line "$(status_for_value_equal /proc/sys/vm/dirty_ratio "$DIRTY_RATIO")" "vm.dirty_ratio = $DIRTY_RATIO" "$(current_sysctl_value /proc/sys/vm/dirty_ratio)"
  status_line "$(status_for_value_equal /proc/sys/vm/dirty_background_ratio "$DIRTY_BACKGROUND_RATIO")" "vm.dirty_background_ratio = $DIRTY_BACKGROUND_RATIO" "$(current_sysctl_value /proc/sys/vm/dirty_background_ratio)"
  status_line "$(status_for_value_equal /proc/sys/vm/vfs_cache_pressure "$VFS_CACHE_PRESSURE")" "vm.vfs_cache_pressure = $VFS_CACHE_PRESSURE" "$(current_sysctl_value /proc/sys/vm/vfs_cache_pressure)"
  status_line "$(status_for_limit_nofile_ok)" "$(msg label_limitnofile)" "$(current_limit_nofile_value)"
  status_line "$(status_for_numa_balancing_ok)" "$(msg label_numa)" "$(current_numa_balancing_value)"
  status_line "$(status_for_innodb_flush_method_ok)" "$(msg label_innodb_flush_method)" "$(current_innodb_flush_method_value)"
  status_line "$(status_for_scheduler_ok)" "$(msg label_scheduler)" "$(current_scheduler_value)"
  status_line "$(status_for_readahead_ok)" "$(msg label_readahead)" "$(current_readahead_value)"
  status_line "$(status_for_nr_requests_ok)" "$(msg label_nr_requests)" "$(current_nr_requests_value)"
}

print_checklist_after() {
  step "$(msg checklist_after)"

  status_line "$(is_mariadb_active && echo 1 || echo 0)" "$(msg label_service_active)"
  status_line "$(status_for_datadir_detected)" "$(msg label_datadir_detected)"
  status_line "$(status_for_datadir_separate_fs)" "$(msg label_datadir_separate_fs)"
  status_line "$(status_for_mountpoint_identified)" "$(msg label_mountpoint_identified)"
  status_line "$(is_target_device_present && echo 1 || echo 0)" "$(msg label_target_device_present)"
  status_line "$(status_for_target_uuid_present)" "$(msg label_target_uuid_present)"
  status_line "$(status_for_target_fs_present)" "$(msg label_target_fs_present)"
  status_line "$(status_for_datadir_mount_in_fstab)" "$(msg label_datadir_fstab_present)"
  status_line "$(status_for_datadir_mount_optimized_in_fstab)" "$(msg label_datadir_fstab_opts)"
  status_line "$(status_for_datadir_mount_mounted)" "$(msg label_datadir_mounted)"
  status_line "$(status_for_thp_enabled_never)" "THP enabled = never"
  status_line "$(status_for_thp_defrag_never)" "THP defrag = never"
  status_line "$(status_for_value_equal /proc/sys/vm/swappiness "$SWAPPINESS")" "vm.swappiness = $SWAPPINESS"
  status_line "$(status_for_value_equal /proc/sys/vm/dirty_ratio "$DIRTY_RATIO")" "vm.dirty_ratio = $DIRTY_RATIO"
  status_line "$(status_for_value_equal /proc/sys/vm/dirty_background_ratio "$DIRTY_BACKGROUND_RATIO")" "vm.dirty_background_ratio = $DIRTY_BACKGROUND_RATIO"
  status_line "$(status_for_value_equal /proc/sys/vm/vfs_cache_pressure "$VFS_CACHE_PRESSURE")" "vm.vfs_cache_pressure = $VFS_CACHE_PRESSURE"
  status_line "$(status_for_limit_nofile_ok)" "$(msg label_limitnofile)"
  status_line "$(status_for_numa_balancing_ok)" "$(msg label_numa)"
  status_line "$(status_for_innodb_flush_method_ok)" "$(msg label_innodb_flush_method)"
  status_line "$(status_for_scheduler_ok)" "$(msg label_scheduler)"
  status_line "$(status_for_readahead_ok)" "$(msg label_readahead)" "$(current_readahead_value)"
  status_line "$(status_for_nr_requests_ok)" "$(msg label_nr_requests)" "$(current_nr_requests_value)"
}

show_pre_state() {
  step "$(msg preamble_storage)"
  if is_virtualized_host; then
    kv_line "$(msg hv_detected)" "$(msg yes)"
  else
    kv_line "$(msg hv_detected)" "$(msg no)"
  fi
  kv_line "$(msg virtualization)" "$(current_virtualization_value)"
  if is_datadir_on_nvme; then
    kv_line "$(msg datadir_nvme)" "$(msg yes)"
  else
    kv_line "$(msg datadir_nvme)" "$(msg no)"
  fi
  if is_virtualized_host; then
    kv_line "$(msg question_validate)" "$(msg question_backend_nvme)"
    kv_line "$(msg guest_scheduler_label)" "$(msg guest_scheduler_note)"
  fi
  kv_line "$(msg detail)" "$(current_datadir_disk_value)"
  echo

  step "$(msg state_before)"
  print_host_resources
  echo
  print_datadir_diagnostics
  print_tuning_status
  echo
  echo -e "${BOLD}${CYAN}$(printf '%-22s' "$(msg target_fstab_entry)")${NC} :"
  get_target_fstab_line || echo "Aucune"
  kv_line "$(msg proposed_line)" "$(fstab_line_for_target)"
}

apply_sysctl() {
  cat > "$SYSCTL_FILE" <<EOF
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = ${DIRTY_RATIO}
vm.dirty_background_ratio = ${DIRTY_BACKGROUND_RATIO}
vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}
EOF
  sysctl --system >/tmp/mariadb_sysctl.log 2>&1
}

apply_thp() {
  [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]] && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true
  [[ -w /sys/kernel/mm/transparent_hugepage/defrag ]] && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true

  cat > "$THP_SERVICE" <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then echo never > /sys/kernel/mm/transparent_hugepage/enabled; fi'
ExecStart=/bin/sh -c 'if [ -w /sys/kernel/mm/transparent_hugepage/defrag ]; then echo never > /sys/kernel/mm/transparent_hugepage/defrag; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable disable-thp.service >/dev/null
  systemctl start disable-thp.service || true
}

apply_scheduler() {
  local scheduler disk file
  scheduler="$(choose_scheduler)"
  disk="$(get_disk_name)"
  file="$(get_scheduler_file)"

  if [[ -f "$file" ]] && grep -qw "$scheduler" "$file"; then
    echo "$scheduler" > "$file" || true
  fi

  cat > "$UDEV_RULE" <<EOF
ACTION=="add|change", KERNEL=="${disk}", ATTR{queue/scheduler}="${scheduler}"
EOF

  udevadm control --reload-rules || true
}

apply_block_settings() {
  local ra nr_file ra_file disk ra_sectors
  ra="$(suggest_readahead_kb)"
  nr_file="$(get_nr_requests_file)"
  ra_file="$(get_ra_file)"
  disk="$(get_disk_path)"

  if [[ -w "$ra_file" ]]; then
    echo "$ra" > "$ra_file" || true
  elif command_exists blockdev; then
    ra_sectors=$(( ra * 2 ))
    blockdev --setra "$ra_sectors" "$disk" || true
  fi

  if [[ -w "$nr_file" ]]; then
    echo "$(suggest_nr_requests)" > "$nr_file" 2>/dev/null || warn "Impossible d'appliquer nr_requests=$(suggest_nr_requests) sur $(get_disk_name)"
  fi
}

apply_fstab_change() {
  local line
  mkdir -p "$TARGET_MOUNT"
  line="$(fstab_line_for_target)"

  if has_fstab_entry_for_mount; then
    warn "Une entrée fstab existe déjà pour ${TARGET_MOUNT} ou ${ALT_TARGET_MOUNT}"
    get_target_fstab_line || true
  else
    echo "$line" >> "$FSTAB_FILE"
    info "Entrée ajoutée dans fstab"
  fi
}

show_post_state() {
  step "ÉTAT APRÈS"
  print_datadir_diagnostics
  echo
  print_tuning_status
  echo
  echo "Entrée fstab cible    :"
  get_target_fstab_line || echo "Aucune"
  echo
  echo "Test mount -a         :"
  if mount -a >/tmp/mariadb_mounta.log 2>&1; then
    echo "OK"
  else
    echo "ECHEC"
    cat /tmp/mariadb_mounta.log
  fi
  echo
  echo "Montage ${TARGET_MOUNT} :"
  if [[ -n "$(get_target_mounted_path)" ]]; then
    findmnt "$(get_target_mounted_path)" || true
  else
    echo "Aucun"
  fi
}

verify_applied_changes() {
  local failed=0

  cache_reset_all

  if [[ "$(status_for_value_equal /proc/sys/vm/swappiness "$SWAPPINESS")" != "1" ]]; then
    err "vm.swappiness attendu=${SWAPPINESS} actuel=$(current_sysctl_value /proc/sys/vm/swappiness)"
    failed=1
  fi
  if [[ "$(status_for_value_equal /proc/sys/vm/dirty_ratio "$DIRTY_RATIO")" != "1" ]]; then
    err "vm.dirty_ratio attendu=${DIRTY_RATIO} actuel=$(current_sysctl_value /proc/sys/vm/dirty_ratio)"
    failed=1
  fi
  if [[ "$(status_for_value_equal /proc/sys/vm/dirty_background_ratio "$DIRTY_BACKGROUND_RATIO")" != "1" ]]; then
    err "vm.dirty_background_ratio attendu=${DIRTY_BACKGROUND_RATIO} actuel=$(current_sysctl_value /proc/sys/vm/dirty_background_ratio)"
    failed=1
  fi
  if [[ "$(status_for_value_equal /proc/sys/vm/vfs_cache_pressure "$VFS_CACHE_PRESSURE")" != "1" ]]; then
    err "vm.vfs_cache_pressure attendu=${VFS_CACHE_PRESSURE} actuel=$(current_sysctl_value /proc/sys/vm/vfs_cache_pressure)"
    failed=1
  fi
  if [[ "$(status_for_thp_enabled_never)" != "1" ]]; then
    err "THP enabled attendu=never actuel=$(current_thp_enabled_value)"
    failed=1
  fi
  if [[ "$(status_for_thp_defrag_never)" != "1" ]]; then
    err "THP defrag attendu=never actuel=$(current_thp_defrag_value)"
    failed=1
  fi
  if [[ "$(status_for_target_fstab_present)" != "1" ]]; then
    err "Entrée fstab cible absente pour ${TARGET_MOUNT}"
    failed=1
  fi
  if [[ "$(status_for_target_fstab_optimized)" != "1" ]]; then
    err "Options fstab cible attendues=$(expected_mount_opts) actuelles=$(current_target_mount_opts_value)"
    failed=1
  fi
  if [[ "$(status_for_readahead_ok)" != "1" ]]; then
    err "read_ahead_kb attendu=$(suggest_readahead_kb) actuel=$(current_sysctl_value "$(get_ra_file)")"
    failed=1
  fi
  if [[ "$(status_for_nr_requests_ok)" != "1" ]]; then
    err "nr_requests attendu=$(suggest_nr_requests) actuel=$(current_sysctl_value "$(get_nr_requests_file)")"
    failed=1
  fi
  if [[ "$(status_for_scheduler_ok)" == "0" ]]; then
    err "Scheduler attendu=$(choose_scheduler) actuel=$(current_scheduler_value)"
    failed=1
  fi

  return "$failed"
}

print_dry_run_commands() {
  local scheduler disk file ra nr_file ra_file ra_sectors line

  scheduler="$(choose_scheduler)"
  disk="$(get_disk_name)"
  file="$(get_scheduler_file)"
  ra="$(suggest_readahead_kb)"
  nr_file="$(get_nr_requests_file)"
  ra_file="$(get_ra_file)"
  ra_sectors=$(( ra * 2 ))
  line="$(fstab_line_for_target)"

  step "$(msg mode_dry_run)"
  echo "$(msg none_applied)"
  echo
  echo "$(msg cmds_would_run)"
  echo
  echo "1) $(msg dryrun_sysctl)"
  echo "   $(msg write_file) ${SYSCTL_FILE}"
  cat <<EOF
   vm.swappiness = ${SWAPPINESS}
   vm.dirty_ratio = ${DIRTY_RATIO}
   vm.dirty_background_ratio = ${DIRTY_BACKGROUND_RATIO}
   vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}
EOF
  echo "   sysctl --system"
  echo
  echo "2) $(msg dryrun_thp)"
  echo "   echo never > /sys/kernel/mm/transparent_hugepage/enabled"
  echo "   echo never > /sys/kernel/mm/transparent_hugepage/defrag"
  echo "   $(msg write_file) ${THP_SERVICE}"
  echo "   systemctl daemon-reload"
  echo "   systemctl enable disable-thp.service"
  echo "   systemctl start disable-thp.service"
  echo
  echo "3) $(msg dryrun_scheduler)"
  echo "   echo ${scheduler} > ${file}"
  echo "   $(msg write_file) ${UDEV_RULE}"
  echo "   ACTION==\"add|change\", KERNEL==\"${disk}\", ATTR{queue/scheduler}=\"${scheduler}\""
  echo "   udevadm control --reload-rules"
  echo
  echo "4) $(msg dryrun_block)"
  echo "   echo ${ra} > ${ra_file}"
  echo "   $(msg fallback_cmd): blockdev --setra ${ra_sectors} $(get_disk_path)"
  echo "   echo $(suggest_nr_requests) > ${nr_file}"
  echo
  echo "5) $(msg dryrun_fstab)"
  echo "   mkdir -p ${TARGET_MOUNT}"
  echo "   $(msg append_to) ${FSTAB_FILE}:"
  echo "   ${line}"
  echo
  echo "6) $(msg verify_after_apply)"
  echo "   $(msg reread_after_apply)"
}

MENU_LANG_CODES=(en fr ru zh)
MENU_LANG_LABELS=(EN FR RU ZH)
MENU_ITEM_KEYS=(opt_check opt_dry_run opt_apply opt_help opt_author opt_license opt_version opt_quit)
MENU_ITEM_MODES=(--check --dry-run --apply --help --author --license --version __quit__)

# External terminal UI library.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/tui_menu.sh"

interactive_menu() {
  run_interactive_menu
}

main() {
  local interactive_session=0

  if [[ $# -eq 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then
      interactive_session=1
    else
      print_help
      exit 0
    fi
  else
    parse_args "$@"
  fi

  while true; do
    if [[ "$interactive_session" == "1" ]]; then
      interactive_menu
    fi

    if [[ "$MODE" == "--help" || "$MODE" == "-h" ]]; then
      print_help
      [[ "$interactive_session" == "1" ]] && { wait_for_menu_return; continue; }
      exit 0
    fi

    if [[ "$MODE" == "--author" || "$MODE" == "--authour" ]]; then
      print_author
      [[ "$interactive_session" == "1" ]] && { wait_for_menu_return; continue; }
      exit 0
    fi

    if [[ "$MODE" == "--license" || "$MODE" == "--lisense" ]]; then
      print_license
      [[ "$interactive_session" == "1" ]] && { wait_for_menu_return; continue; }
      exit 0
    fi

    if [[ "$MODE" == "--version" ]]; then
      print_version
      [[ "$interactive_session" == "1" ]] && { wait_for_menu_return; continue; }
      exit 0
    fi

    if [[ "$MODE" == "--install-man" ]]; then
      require_root
      install_man_page
      [[ "$interactive_session" == "1" ]] && { wait_for_menu_return; continue; }
      exit 0
    fi

    if [[ "$MODE" != "--check" && "$MODE" != "--apply" && "$MODE" != "--dry-run" ]]; then
      err "$(msg err_unknown_option "$MODE")"
      echo
      print_help
      exit 1
    fi

    require_root

    if [[ ! -b "$TARGET_DEVICE" ]]; then
      err "$(msg err_missing_device "$TARGET_DEVICE")"
      exit 1
    fi

    step "$(msg summary_target)"
    kv_line "$(msg label_target_device_present)" "${TARGET_DEVICE}"
    kv_line "UUID" "$(get_uuid "$TARGET_DEVICE")"
    kv_line "$(msg filesystem)" "$(get_fstype_device "$TARGET_DEVICE")"
    kv_line "$(msg mounted_target)" "${TARGET_MOUNT}"
    kv_line "$(msg mount_options)" "$(expected_mount_opts)"
    kv_line "$(msg proposed_line)" "$(fstab_line_for_target)"

    show_pre_state
    print_checklist_before

    if [[ "$MODE" == "--apply" ]]; then
      step "$(msg application)"
      apply_sysctl
      apply_thp
      apply_scheduler
      apply_block_settings
      apply_fstab_change
      if ! verify_applied_changes; then
        err "$(msg err_apply_not_conform)"
        [[ "$interactive_session" == "1" ]] && { wait_for_menu_return; continue; }
        exit 1
      fi
      show_post_state
      print_checklist_after
    elif [[ "$MODE" == "--dry-run" ]]; then
      print_dry_run_commands
    else
      step "$(msg mode_check)"
      echo "$(msg none_applied)"
      echo "$(msg apply_hint)"
    fi

    [[ "$interactive_session" == "1" ]] && { wait_for_menu_return; continue; }
    break
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
