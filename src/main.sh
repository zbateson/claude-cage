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
echo "  Isolation:     $cfg_isolationMode"
echo "  Source:        $cfg_source"
echo "  Mounted as:    $cfg_mounted"
echo "  Network mode:  $cfg_networkMode"
echo "  Direct mount:  $cfg_directMount"
echo "  Isolated:      $cfg_isolated"

if [ "$cfg_isolationMode" = "docker" ]; then
    echo ""
    echo "Docker config:"
    echo "  Image:         $cfg_docker_image"
    echo "  Name prefix:   $cfg_docker_namePrefix"
    [ -n "$cfg_docker_packages" ] && echo "  Packages:      $cfg_docker_packages"
    [ -n "$cfg_docker_container" ] && echo "  Container:     $cfg_docker_container"
fi

if [ ${#cfg_homeConfigSync[@]} -gt 0 ]; then
    echo ""
    echo "Home config sync entries: ${#cfg_homeConfigSync[@]}"
    for entry in "${cfg_homeConfigSync[@]}"; do
        echo "  $entry"
    done
fi

if [ ${#cfg_display_lines[@]} -gt 0 ]; then
    echo ""
    echo "Config items by source:"
    for line in "${cfg_display_lines[@]}"; do
        echo "  $line"
    done
fi

echo ""

# Create the intermediary clone
create_intermediary_clone "$cfg_source"
