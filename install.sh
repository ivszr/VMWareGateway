#!/bin/bash

# ==============================================================================
# Скрипт для автоматической установки и настройки.
# Запускать от имени обычного пользователя с правами sudo.
# ==============================================================================

# --- Цвета для вывода ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Глобальные переменные ---
# Определяем пользователя и его домашний каталог
AUTOLOGIN_USER=$(whoami)
USER_HOME=$HOME

# --- Функции ---

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# 1. Проверка прав и запрос пароля sudo в самом начале
check_privileges() {
 if [[ $(id -u) -eq 0 ]]; then
  log_error "Этот скрипт не предназначен для запуска от имени root. Запустите его от обычного пользователя."
 fi

 if ! command -v sudo &> /dev/null; then
  log_error "Команда 'sudo' не найдена. Установите sudo и настройте права для пользователя '$AUTOLOGIN_USER'."
 fi

 log_info "Запрашиваю права sudo для выполнения системных команд..."
 # sudo -v обновляет кэшированный пароль. Если его нет, запрашивает.
 if ! sudo -v; then
  log_error "Не удалось получить права sudo. Проверьте пароль или настройки sudoers."
 fi

 # Запускаем цикл в фоне, чтобы sudo "не засыпал" во время выполнения скрипта
 # Это предотвращает повторный запрос пароля на долгих операциях (вроде apt install)
 while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done &
 SUDO_KEEPALIVE_PID=$!
 # Убиваем фоновый процесс при выходе из скрипта
 trap 'kill "$SUDO_KEEPALIVE_PID" &>/dev/null' EXIT

 log_info "Права sudo успешно получены. Начинаю установку..."
}

# 2. Установка всех зависимостей
install_dependencies() {
 log_info "Обновление списка пакетов..."
 sudo apt-get update -y || log_error "Не удалось обновить список пакетов."

 log_info "Установка сетевых зависимостей: wget, procps, iproute2, dnsmasq, iptables..."
 sudo apt-get install -y wget procps iproute2 dnsmasq iptables bash || log_error "Не удалось установить сетевые зависимости."

 log_info "Установка GUI и утилит: xorg, openbox, tint2, gedit, polkitd..."
 sudo apt-get install -y xorg openbox tint2 gedit polkitd desktop-file-utils || log_error "Не удалось установить графические компоненты."

 log_info "Отключение стандартной службы dnsmasq..."
 sudo systemctl disable dnsmasq &>/dev/null || log_warn "Не удалось отключить dnsmasq."
}

# 3. Определение и выбор сетевого интерфейса
select_network_interface() {
 # Эта функция почти не изменилась, так как `ip` не требует root для чтения
 log_info "Определение сетевых интерфейсов..."
 local primary_interface=$(ip route | grep default | awk '{print $5}' | head -n 1)
 [[ -n "$primary_interface" ]] && log_info "Обнаружен основной интерфейс (интернет): ${YELLOW}$primary_interface${NC}"

 local interfaces=($(ls /sys/class/net/ | grep -v "lo\|$primary_interface\|sit\|veth\|docker\|virbr\|tun"))
 if [[ ${#interfaces[@]} -eq 0 ]]; then
  read -p "Не найдены доп. интерфейсы. Введите имя LAN-интерфейса вручную: " selected_interface
  [[ -z "$selected_interface" ]] && log_error "Имя интерфейса не может быть пустым."
 else
  local suggested_interface="${interfaces[0]}"
  read -p "Использовать '${YELLOW}$suggested_interface${NC}'? [Y/n] или введите другое имя: " user_input
  if [[ -z "$user_input" || "$user_input" =~ ^[YyДд]$ ]]; then
   selected_interface="$suggested_interface"
  elif [[ "$user_input" =~ ^[NnНн]$ ]]; then
   read -p "Введите имя интерфейса: " selected_interface
   [[ -z "$selected_interface" ]] && log_error "Имя интерфейса не может быть пустым."
  else
   selected_interface="$user_input"
  fi
 fi
 ! ip link show "$selected_interface" &>/dev/null && log_error "Интерфейс '$selected_interface' не существует."
 log_info "Выбран интерфейс для шлюза:${YELLOW}$selected_interface${NC}"
 export LAN_INTERFACE="$selected_interface"
}

# 4. Настройка автологина через systemd/agetty
setup_autologin() {
 log_info "Настройка автологина для пользователя '$AUTOLOGIN_USER' на tty1..."
 local override_dir="/etc/systemd/system/getty@tty1.service.d"
 sudo mkdir -p "$override_dir"

 # Используем `sudo tee` для записи в системный каталог от имени root
 cat << EOF | sudo tee "${override_dir}/override.conf" > /dev/null
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $AUTOLOGIN_USER --noclear %I \$TERM
EOF

 sudo systemctl daemon-reload
 log_info "Автологин успешно настроен."
}

# 5. Настройка автозапуска Openbox, Tint2 и кнопки выключения
configure_gui() {
 log_info "Настройка пользовательских конфигов для '$AUTOLOGIN_USER'..."

 # Настройка .bash_profile для автозапуска startx
 # Не требует sudo, так как выполняется в домашнем каталоге пользователя
 cat << EOF > "$USER_HOME/.bash_profile"
# Autostart X-session on tty1
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
 exec startx
fi
EOF

 # Создаем конфиги Openbox и Tint2
 local config_dir="$USER_HOME/.config"
 mkdir -p "$config_dir/openbox" "$config_dir/tint2"

 # Файл автозапуска Openbox
 cat << EOF > "$config_dir/openbox/autostart"
# Запуск панели Tint2 в фоновом режиме
(sleep 1 && tint2) &
EOF

 # Конфигурация Tint2
 cat << EOF > "$config_dir/tint2/tint2rc"
#---- Generated by tint2conf 5771 ----
# See https://gitlab.com/o9000/tint2/wikis/Configure for 
# full documentation of the configuration options.
#-------------------------------------
# Gradients
#-------------------------------------
# Backgrounds
# Background 1: Panel
rounded = 0
border_width = 1
border_sides = TBLR
border_content_tint_weight = 0
background_content_tint_weight = 0
background_color = #eeeeee 100
border_color = #bbbbbb 100
background_color_hover = #eeeeee 100
border_color_hover = #bbbbbb 100
background_color_pressed = #eeeeee 100
border_color_pressed = #bbbbbb 100

# Background 2: Default task, Iconified task
rounded = 5
border_width = 1
border_sides = TBLR
border_content_tint_weight = 0
background_content_tint_weight = 0
background_color = #eeeeee 100
border_color = #eeeeee 100
background_color_hover = #eeeeee 100
border_color_hover = #cccccc 100
background_color_pressed = #cccccc 100
border_color_pressed = #cccccc 100

# Background 3: Active task
rounded = 5
border_width = 1
border_sides = TBLR
border_content_tint_weight = 0
background_content_tint_weight = 0
background_color = #dddddd 100
border_color = #999999 100
background_color_hover = #eeeeee 100
border_color_hover = #aaaaaa 100
background_color_pressed = #cccccc 100
border_color_pressed = #999999 100

# Background 4: Urgent task
rounded = 5
border_width = 1
border_sides = TBLR
border_content_tint_weight = 0
background_content_tint_weight = 0
background_color = #aa4400 100
border_color = #aa7733 100
background_color_hover = #aa4400 100
border_color_hover = #aa7733 100
background_color_pressed = #aa4400 100
border_color_pressed = #aa7733 100

# Background 5: Tooltip
rounded = 2
border_width = 1
border_sides = TBLR
border_content_tint_weight = 0
background_content_tint_weight = 0
background_color = #ffffaa 100
border_color = #999999 100
background_color_hover = #ffffaa 100
border_color_hover = #999999 100
background_color_pressed = #ffffaa 100
border_color_pressed = #999999 100

# Background 6: Inactive desktop name
rounded = 2
border_width = 1
border_sides = TBLR
border_content_tint_weight = 0
background_content_tint_weight = 0
background_color = #eeeeee 100
border_color = #cccccc 100
background_color_hover = #eeeeee 100
border_color_hover = #cccccc 100
background_color_pressed = #eeeeee 100
border_color_pressed = #cccccc 100

# Background 7: Active desktop name
rounded = 2
border_width = 1
border_sides = TBLR
border_content_tint_weight = 0
background_content_tint_weight = 0
background_color = #dddddd 100
border_color = #999999 100
background_color_hover = #dddddd 100
border_color_hover = #999999 100
background_color_pressed = #dddddd 100
border_color_pressed = #999999 100

# Background 8: Systray
rounded = 3
border_width = 0
border_sides = TBLR
border_content_tint_weight = 0
background_content_tint_weight = 0
background_color = #dddddd 100
border_color = #cccccc 100
background_color_hover = #dddddd 100
border_color_hover = #cccccc 100
background_color_pressed = #dddddd 100
border_color_pressed = #cccccc 100

#-------------------------------------
# Panel
panel_items = PLTSC
panel_size = 100% 32
panel_margin = 0 0
panel_padding = 4 2 4
panel_background_id = 1
wm_menu = 1
panel_dock = 0
panel_pivot_struts = 0
panel_position = bottom center horizontal
panel_layer = normal
panel_monitor = all
panel_shrink = 0
autohide = 0
autohide_show_timeout = 0
autohide_hide_timeout = 0.5
autohide_height = 2
strut_policy = follow_size
panel_window_name = tint2
disable_transparency = 0
mouse_effects = 1
font_shadow = 0
mouse_hover_icon_asb = 100 0 10
mouse_pressed_icon_asb = 100 0 0
scale_relative_to_dpi = 0
scale_relative_to_screen_height = 0

#-------------------------------------
# Taskbar
taskbar_mode = single_desktop
taskbar_hide_if_empty = 0
taskbar_padding = 0 0 2
taskbar_background_id = 0
taskbar_active_background_id = 0
taskbar_name = 1
taskbar_hide_inactive_tasks = 0
taskbar_hide_different_monitor = 0
taskbar_hide_different_desktop = 0
taskbar_always_show_all_desktop_tasks = 0
taskbar_name_padding = 6 3
taskbar_name_background_id = 6
taskbar_name_active_background_id = 7
taskbar_name_font = sans Bold 9
taskbar_name_font_color = #222222 100
taskbar_name_active_font_color = #222222 100
taskbar_distribute_size = 1
taskbar_sort_order = none
task_align = left

#-------------------------------------
# Task
task_text = 1
task_icon = 1
task_centered = 1
urgent_nb_of_blink = 100000
task_maximum_size = 140 35
task_padding = 4 3 4
task_font = sans 8
task_tooltip = 1
task_thumbnail = 0
task_thumbnail_size = 210
task_font_color = #222222 100
task_icon_asb = 100 0 0
task_background_id = 2
task_active_background_id = 3
task_urgent_background_id = 4
task_iconified_background_id = 2
mouse_left = toggle_iconify
mouse_middle = none
mouse_right = close
mouse_scroll_up = prev_task
mouse_scroll_down = next_task

#-------------------------------------
# System tray (notification area)
systray_padding = 4 0 2
systray_background_id = 8
systray_sort = ascending
systray_icon_size = 22
systray_icon_asb = 100 0 0
systray_monitor = 1
systray_name_filter = 

#-------------------------------------
# Launcher
launcher_padding = 0 0 2
launcher_background_id = 0
launcher_icon_background_id = 0
launcher_icon_size = 22
launcher_icon_asb = 100 0 0
launcher_icon_theme_override = 0
startup_notifications = 1
launcher_tooltip = 1
launcher_item_app = tint2conf.desktop
launcher_item_app = firefox.desktop
launcher_item_app = iceweasel.desktop
launcher_item_app = chromium-browser.desktop
launcher_item_app = google-chrome.desktop
launcher_item_app = x-terminal-emulator.desktop

#-------------------------------------
# Clock
time1_format = %H:%M
time2_format = %A %d %B
time1_font = sans Bold 8
time1_timezone = 
time2_timezone = 
time2_font = sans 7
clock_font_color = #222222 100
clock_padding = 1 0
clock_background_id = 0
clock_tooltip = 
clock_tooltip_timezone = 
clock_lclick_command = zenity --calendar --text ""
clock_rclick_command = orage
clock_mclick_command = 
clock_uwheel_command = 
clock_dwheel_command = 

#-------------------------------------
# Battery
battery_tooltip = 1
battery_low_status = 10
battery_low_cmd = xmessage 'tint2: Battery low!'
battery_full_cmd = 
bat1_font = sans 8
bat2_font = sans 6
battery_font_color = #222222 100
bat1_format = 
bat2_format = 
battery_padding = 1 0
battery_background_id = 0
battery_hide = 101
battery_lclick_command = 
battery_rclick_command = 
battery_mclick_command = 
battery_uwheel_command = 
battery_dwheel_command = 
ac_connected_cmd = 
ac_disconnected_cmd = 

#-------------------------------------
# Button 1
button = new
button_text = OFF
button_lclick_command = systemctl poweroff
button_rclick_command = systemctl poweroff
button_mclick_command = 
button_uwheel_command = 
button_dwheel_command = 
button_font_color = #000000 100
button_padding = 0 0
button_background_id = 0
button_centered = 0
button_max_icon_size = 0

#-------------------------------------
# Tooltip
tooltip_show_timeout = 0.5
tooltip_hide_timeout = 0.1
tooltip_padding = 2 2
tooltip_background_id = 5
tooltip_font_color = #222222 100
tooltip_font = sans 9
EOF

 log_info "Пользовательские конфиги созданы в $config_dir"
}

# 6. Установка и настройка lnxrouter
setup_lnxrouter() {
 local lnxrouter_path="/bin/lnxrouter"
 local service_path="/etc/systemd/system/gateway.service"
 log_info "Загрузка и настройка lnxrouter..."

 # Загружаем файл с помощью curl/wget и сразу передаем его в `sudo tee` для записи
 wget -O - https://raw.githubusercontent.com/garywill/linux-router/refs/heads/master/lnxrouter | sudo tee "$lnxrouter_path" > /dev/null || log_error "Не удалось загрузить lnxrouter."
 sudo chmod u+x "$lnxrouter_path"

 # Создание службы с помощью `sudo tee`
 cat << EOF | sudo tee "$service_path" > /dev/null
[Unit]
Description=Linux as router service
After=network.target
[Service]
Type=simple
ExecStart=$lnxrouter_path -i $LAN_INTERFACE -g 192.168.133.1 -o singbox_tun
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

 sudo chmod u+x "$service_path"
 sudo systemctl daemon-reload
 sudo systemctl enable gateway
}

# 7. Установка v2rayN
install_v2rayn() {
 local v2rayn_deb_url="https://github.com/2dust/v2rayN/releases/latest/download/v2rayN-linux-64.deb"
 local v2rayn_deb_file="v2rayN-linux-64.deb"

 log_info "Загрузка последней версии v2rayN..."
 wget -O "$v2rayn_deb_file" "$v2rayn_deb_url" || log_error "Не удалось скачать v2rayN."

 log_info "Установка v2rayN из .deb пакета..."
 sudo apt install -y "./$v2rayn_deb_file" || log_error "Не удалось установить v2rayN."

 log_info "Очистка загруженного файла..."
 rm "./$v2rayn_deb_file"
}

# --- Основной блок выполнения ---
main() {
 check_privileges

 log_info "Настройка будет выполнена для пользователя: ${YELLOW}$AUTOLOGIN_USER${NC}"
 read -p "Продолжить? [Y/n] " confirm
 if [[ "$confirm" =~ ^[NnНн]$ ]]; then
  echo "Установка отменена."
  exit 0
 fi

 install_dependencies
 select_network_interface
 setup_autologin
 configure_gui
 setup_lnxrouter
 install_v2rayn

 log_info "--------------------------------------------------"
 log_info "${GREEN}Установка и настройка полностью завершены!${NC}"
 log_info ">>> ${YELLOW}РЕКОМЕНДУЕТСЯ ПЕРЕЗАГРУЗИТЬ СИСТЕМУ СЕЙЧАС${NC} <<<"
 log_info "Команда для перезагрузки: ${YELLOW}sudo reboot${NC}"
 log_info "--------------------------------------------------"
}

# Запуск главной функции
main
