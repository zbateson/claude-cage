# Parse additional flags
test_mode=false
for arg in "$@"; do
    case "$arg" in
        --test) test_mode=true ;;
    esac
done

# Initialize and parse config
init_config "$@"

# Check bwrap is available
check_bwrap

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

# Create the intermediary clone and work directory
create_intermediary_clone "$cfg_source"

# Paths for bwrap
caged_dir="$cfg_source/.caged"
project_path="$cfg_source"

echo ""
echo "============================================"
echo ""
echo "Sandbox mount:"
echo "  $caged_dir"
echo "    -> $project_path/"
echo ""
echo "Inside sandbox:"
echo "  $project_path/intermediary/  (git origin)"
echo "  $project_path/work/          (working dir)"

if [ "$test_mode" = true ]; then
    echo ""
    echo "Droppin' you into the bwrap sandbox for testing..."
    run_in_bwrap "$caged_dir" "$project_path"
else
    echo ""
    echo "Use --test to drop into a shell for testing."
fi
