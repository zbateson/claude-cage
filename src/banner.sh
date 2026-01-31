print_banner() {
    local banner=$(cat << 'EOF'



   ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗
  ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝
  ██║     ██║     ███████║██║   ██║██║  ██║█████╗
  ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝
  ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗
   ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝
                  ___________
                .'           '.
               /  -_-    -_-   \
              |    (_)  (_)     |
              |                 |          ,----.
              |      .---.      |         /||||||\
               \    '.__.'     /         | ||||||.|
                '.          .'           | |||||| |
                  '-._____.-'            | |||||| |
                      |||                |_||||||_|
                     /|||\                 \    /
                    / ||| \                 |  |

        ██████╗ █████╗  ██████╗ ███████╗
        ██╔════╝██╔══██╗██╔════╝ ██╔════╝
        ██║     ███████║██║  ███╗█████╗
        ██║     ██╔══██║██║   ██║██╔══╝
        ╚██████╗██║  ██║╚██████╔╝███████╗
         ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝


EOF
)

    # ANSI color codes
    local yellow='\033[33m'
    local reset='\033[0m'

    # Print banner line by line with a slight delay for "slide up" effect
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        # Lines 4-9 are CLAUDE (after 3 blank lines), lines 23-28 are CAGE
        if (( line_num >= 4 && line_num <= 9 )) || (( line_num >= 23 && line_num <= 28 )); then
            echo -e "${yellow}${line}${reset}"
        else
            echo "$line"
        fi
        sleep 0.01
    done <<< "$banner"
    sleep 0.3
}
