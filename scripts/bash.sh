#!/usr/bin/env bash
# Make sure the script stops if any single command fails
set -e

echo "=== Starting Root Shell Configuration ==="
xbps-install -u xbps
# 1. Change root's default login shell from dash to bash
echo "-> Changing default shell to /bin/bash..."
sudo chsh -s /bin/bash root

# 2. Install the advanced tab-completion packages from XBPS
echo "-> Installing bash-completion package..."
sudo xbps-install -Sy bash-completion
sudo ln -s /usr/share/bash-completion/bash_completion /etc/profile.d/bash-completion.sh
sudo curl -sS https://starship.rs/install.sh | sh

# 3. Copy the skeleton profile layout template to root's home directory
echo "-> Copying skeleton profile files to /root..."
sudo cp /etc/skel/.bashrc /root/
sudo cp /etc/skel/.bash_profile /root/

sudo cat << 'EOF' > /etc/starship.toml
# Main layout format string
format = "\\[$username$hostname$directory\\]$character"

[username]
show_always = true
format = "[$user]($style)"
style_user = "bold white"     # VS Code Mint Green  # Colors regular accounts (e.g., jack)
style_root = "#05DDFF"       # Colors the root user

#[username.aliases]
#"root" = "root"                  # Shifts the text string from 'root' to '#'
#style = "bright cyan"

[hostname]
ssh_only = false
# Crucial logic: By using the format tag variables correctly,
# the '@' symbol drops entirely if Starship reads the username alias as '#'
format = "[@$hostname](#569CD6)"

[directory]
format = " [$path](#4FC1FF)"
truncation_length = 1         # Displays ONLY the last folder name
truncate_to_repo = false      # Keeps it short even inside git projects
style = "bold purple"

[character]
success_symbol = "[\\$ ](white)"
error_symbol = "[\\$ ](#D4D4D4)"
EOF
# 4. Inject the Red Alert / Color prompt and alias into root's .bashrc
echo "-> Injecting color theme and global terminal settings..."
sudo tee -a /root/.bashrc > /dev/null << 'EOF'

# --- Custom System Additions ---
if [ "$(tty)" = "/dev/ttyAMA0" ] || [ "$(tty)" = "/dev/ttyS0" ]; then
    export TERM=linux
fi
# Bold Red Alert prompt for Root management awareness
#export PS1="\[\e[1;31m\][ROOT] \u\[\e[m\]:\[\e[1;33m\]\w\[\e[m\]\\$ "

# Turn on global terminal colors for directories and files
alias ls='ls --color=auto'

# Dynamically activate the advanced tab-intellisense module
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi


# Explicit environment fallback hooks specifically for sudo su context
if [ -n "$PS1" ]; then
    export STARSHIP_CONFIG=/etc/starship.toml

    # Custom vs-code ls file types and directory parameters
    alias ls='ls -h --color=auto'
    alias ll='ls -lh --color=auto'
    export LS_COLORS=$LS_COLORS:"di=01;36:fi=00;37:ex=01;32:ln=01;34:*.tar=01;31:*.zip=01;31:"

    if command -v starship &> /dev/null; then
        eval "$(starship init bash)"
    fi
fi


export EDITOR="/usr/bin/nano"
export VISUAL="/usr/bin/nano"


EOF
sudo cat << 'EOF' > /usr/local/bin/sudo
#!/bin/bash
if [ "$1" = "su" ] && [ -z "$2" ]; then
    /usr/bin/sudo su -
else
    /usr/bin/sudo "$@"
fi
EOF
sudo chmod +x /usr/local/bin/sudo


sudo cat << 'EOF' > /etc/profile.d/sv-status.sh

# System-wide Runit Service Status Helper
sv-status() {
    local svc=$1
    if [ -z "$svc" ]; then 
        echo -e "\e[1;31mError:\e[0m Usage: sv-status <service>"
        return 1
    fi

    # Check if the service actually exists in /var/service
    if [ ! -d "/var/service/$svc" ]; then
        echo -e "\e[1;31mError:\e[0m Service '$svc' is not enabled or does not exist in /var/service/"
        return 1
    fi

    echo -e "\e[1;34m● $svc.service - Runit Service Daemon\e[0m"
    sudo sv status "$svc"

    # 1. Process ID Extraction (Parsing runit status for the true PID)
    local pid=$(sudo sv status "$svc" | awk '{print $4}' | tr -d ')')
    
    # Verify the extracted string is actually a valid integer PID
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        echo -e "\n\e[1;32m   Active Process Metrics:\e[0m"
        ps -o pid,user,%cpu,%mem,start,cmd -p "$pid" | sed 's/^/   /'

        echo -e "\n\e[1;32m   Network & Port Bindings:\e[0m"
        # Search sockets matching this specific PID
        local network_info=$(sudo ss -tlnp 2>/dev/null | grep -E "pid=$pid,")
        if [ -n "$network_info" ]; then
            echo "$network_info" | sed 's/^/   /'
        else
            echo "   No active network ports bound."
        fi
    else
        echo -e "\n\e[1;31m   Service Information:\e[0m"
        echo "   Service is down or process ID could not be determined."
    fi

    # 2. Native Void Linux Socklog / svlogd Integration
    echo -e "\n\e[1;32m   Recent Logs:\e[0m"
  if [ -d "/var/service/$svc/log" ] && [ -f "/var/log/$svc/current" ]; then
        echo "   [Displaying Service-Specific Logs]"
        sudo tail -n 5 "/var/log/$svc/current" | cut -c 26-
    elif [ "$svc" = "socklog-unix" ] && [ -f "/var/log/socklog/secure/current" ]; then
        echo "   [Displaying Secure Auth Logs]"
        sudo tail -n 5 /var/log/socklog/secure/current | cut -c 26-
    else

        echo "   No dedicated log files found for this service."
        echo "   Ensure 'socklog-void' is running or check /var/log/socklog/everything/current"
    fi
}
EOF
sudo chmod 644 /etc/profile.d/sv-status.sh

sudo cat << 'EOF' > /etc/profile.d/void.cloud.sh
if [ -n "$PS1" ]; then
    export STARSHIP_CONFIG=/etc/starship.toml

    # Universal aliases and colors compatible with Bash/Zsh/Sh
     alias ls='ls -h --color=auto'
    alias ll='ls -lh --color=auto'
    alias del='rm -rf'
    alias cache='sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches'
    alias la='ls -A'
    alias xi='sudo xbps-install -S'
    alias xr='sudo xbps-remove -R'
    alias xup='sudo xbps-install -Su'
    alias xs='xbps-query -Rs'

    alias su='sudo -i'
    alias xclean='sudo xbps-remove -Oo'
    alias ff='fastfetch'

    #vs codelike colors
    export LS_COLORS="di=01;36:fi=00;37:ex=01;32:ln=01;34:*.tar=01;31:*.zip=01;31:"

    # Initialize Starship safely based on the active shell name
    if [ -n "$BASH_VERSION" ]; then
        eval "$(starship init bash)"
    elif [ -n "$ZSH_VERSION" ]; then
        eval "$(starship init zsh)"
    fi
fi

# Enable system-wide bash completion
if [ -r /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
fi

export EDITOR="/usr/bin/nano"
export VISUAL="/usr/bin/nano"

EOF
sudo chmod 644 /etc/profile.d/void.cloud.sh
sudo cat << 'EOF' > /etc/profile.d/void.cloud.functions.sh
# Global Void Linux service manager function
service() {
    # Keep locale settings local to the function execution
    local LC_ALL=C
    local LANG=C

    local cmd="$1"
    local service="/etc/sv"
    local serv_where="/var/service"

    if [ -z "$cmd" ]; then
        echo "Error: Please provide a command or use --help for more info"
        return 1
    fi

    if [[ "$cmd" != "list" && "$cmd" != "--h" && "$cmd" != "--help" && -z "$2" ]]; then
        echo "Error: Please provide the service name"
        return 1
    fi

    check_installed() {
        if [ ! -d "$service/$2" ]; then
            echo "Error: Service $2 isn't installed on your computer"
            return 1
        fi
    }

    _help() {
        echo "service - Void Linux service manager

Commands
    link [SERVICE]      - Link a service to active services
    unlink [SERVICE]    - Unlink a service from active services
    relink [SERVICE]    - Relink a service, if previous one is broken
    lnstat [SERVICE]    - Check symlink health
    start [SERVICE]     - Start a service
    restart [SERVICE]   - Restart a service
    stop [SERVICE]      - Stop a service
    status [SERVICE]    - Check service status through sv
    list                - List all currently linked services"
    }

    case "$cmd" in
        link)
            check_installed "$@" || return 1
            echo "Linking $2 to active services..."
            sudo ln -s "$service/$2" "$serv_where/$2"
            ;;
        
        unlink)
            check_installed "$@" || return 1
            echo "Unlinking $2..."
            sudo rm -rf "$serv_where/$2"
            ;;
        
        relink)
            check_installed "$@" || return 1
            echo "Force-relinking $2..."
            sudo ln -sf "$service/$2" "$serv_where/$2"
            ;;
        
        lnstat)
            check_installed "$@" || return 1
            if [ -L "$serv_where/$2" ]; then
                if [ -e "$serv_where/$2" ]; then
                    echo "$2 is working fine"
                else
                    echo "$2 symbolic link is broken"
                fi
            else
                echo "$2 is not linked in $serv_where"
            fi
            ;;

        start)
            check_installed "$@" || return 1
            sudo sv start "$2"
            ;;
        
        restart)
            check_installed "$@" || return 1
            sudo sv restart "$2"
            ;;
        
        stop)
            check_installed "$@" || return 1
            sudo sv stop "$2"
            ;;

        status)
            check_installed "$@" || return 1
            sv status "$2"
            ;;

        list)
            echo "--- Currently Enabled Services ---"
            ls -1 /etc/runit/runsvdir/current
            ;;
        
        --help|--h) _help ;;
        *) _help ;;
    esac
}

EOF
sudo chmod 644 /etc/profile.d/void.cloud.functions.sh

# 5. Enable syntax highlighting for the Nano text editor globally
echo "-> Enabling Nano syntax highlighting..."
if [ -f /etc/nanorc ]; then
    # Uncomment the global include line inside nanorc safely
    sudo sed -i '# include ".*nano.*"/include "\/usr/share\/nano\/*.nanorc"/' /etc/nanorc
else
    # Create the file with the rule if it doesn't exist
    echo 'include "/usr/share/nano/*.nanorc"' | sudo tee /etc/nanorc > /dev/null
fi

echo "=== Configuration Complete! ==="
echo "Please type 'sudo -i' or log back in to see your new colored environment."
