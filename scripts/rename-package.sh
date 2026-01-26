#!/bin/bash

# Usage: ./scripts/rename-package.sh dev.mycompany.myapp
#
# Renames all packages from dev.template to the specified package name.
# Also renames directory structure to match.

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <new-package-name>"
    echo "Example: $0 dev.mycompany.myapp"
    exit 1
fi

OLD_PACKAGE="dev.template"
NEW_PACKAGE="$1"

OLD_PATH=$(echo "$OLD_PACKAGE" | tr '.' '/')
NEW_PATH=$(echo "$NEW_PACKAGE" | tr '.' '/')

echo "Renaming package: $OLD_PACKAGE -> $NEW_PACKAGE"

# 1. Replace in all source files
echo "Updating source files..."
find . -type f \( -name "*.kt" -o -name "*.kts" -o -name "*.md" -o -name "*.yaml" -o -name "*.xml" \) \
    -exec sed -i '' "s/$OLD_PACKAGE/$NEW_PACKAGE/g" {} \;

# 2. Rename directories
echo "Renaming directories..."
find . -type d -path "*/$OLD_PATH" | sort -r | while read dir; do
    parent=$(dirname "$dir")
    new_dir="$parent/$(echo "$NEW_PATH" | cut -d'/' -f1)"

    # Create new directory structure
    mkdir -p "$(dirname "$dir")/$NEW_PATH"

    # Move contents
    if [ -d "$dir" ]; then
        mv "$dir"/* "$(dirname "$dir")/$NEW_PATH/" 2>/dev/null || true

        # Clean up old directories
        rm -rf "$(dirname "$dir")/template" 2>/dev/null || true
    fi
done

# 3. Update settings.gradle.kts project name
echo "Updating project name..."
sed -i '' "s/rootProject.name = \"template\"/rootProject.name = \"$(echo "$NEW_PACKAGE" | rev | cut -d'.' -f1 | rev)\"/" settings.gradle.kts

echo "Done! Package renamed to $NEW_PACKAGE"
echo ""
echo "Next steps:"
echo "1. Review the changes"
echo "2. Update docker-compose.yaml with your schema names"
echo "3. Create your .env file with credentials"
echo "4. ./gradlew build"
