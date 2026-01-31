# Initialize and parse config
init_config "$@"

# Show banner if enabled
if [ "$cfg_showBanner" = "true" ]; then
    print_banner
fi

# Display parsed config
echo "Configuration loaded from: $local_config"
echo ""
echo "  Project:       $cfg_project"
echo "  User:          $cfg_user"
echo "  Source:        $cfg_source"
echo "  Mounted as:    $cfg_mounted"
echo "  Network mode:  $cfg_networkMode"

if [ ${#cfg_display_lines[@]} -gt 0 ]; then
    echo ""
    echo "Excludes by source:"
    for line in "${cfg_display_lines[@]}"; do
        IFS='|' read -r source patterns <<< "$line"
        echo "  [$source] $patterns"
    done
fi

echo ""

# Create the intermediary clone
create_intermediary_clone "$cfg_source"
