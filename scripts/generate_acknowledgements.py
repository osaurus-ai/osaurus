#!/usr/bin/env python3
"""
Generate Acknowledgements.json from Package.resolved files.

This script parses Swift Package Manager Package.resolved files and generates
a JSON file containing license information for all dependencies.

Usage:
    python3 generate_acknowledgements.py

Output:
    App/osaurus/Acknowledgements.json
"""

import json
import os
from pathlib import Path
from typing import Dict, List, Optional

# Known licenses for dependencies
# Format: package_identity -> (license_type, license_url, repository_url)
KNOWN_LICENSES: Dict[str, tuple] = {
    # Apple packages (Apache 2.0)
    "swift-nio": ("Apache 2.0", "https://github.com/apple/swift-nio/blob/main/LICENSE.txt", "https://github.com/apple/swift-nio"),
    "swift-atomics": ("Apache 2.0", "https://github.com/apple/swift-atomics/blob/main/LICENSE.txt", "https://github.com/apple/swift-atomics"),
    "swift-collections": ("Apache 2.0", "https://github.com/apple/swift-collections/blob/main/LICENSE.txt", "https://github.com/apple/swift-collections"),
    "swift-log": ("Apache 2.0", "https://github.com/apple/swift-log/blob/main/LICENSE.txt", "https://github.com/apple/swift-log"),
    "swift-numerics": ("Apache 2.0", "https://github.com/apple/swift-numerics/blob/main/LICENSE", "https://github.com/apple/swift-numerics"),
    "swift-system": ("Apache 2.0", "https://github.com/apple/swift-system/blob/main/LICENSE.txt", "https://github.com/apple/swift-system"),
    "swift-argument-parser": ("Apache 2.0", "https://github.com/apple/swift-argument-parser/blob/main/LICENSE.txt", "https://github.com/apple/swift-argument-parser"),
    
    # Hugging Face packages (Apache 2.0)
    "swift-transformers": ("Apache 2.0", "https://github.com/huggingface/swift-transformers/blob/main/LICENSE", "https://github.com/huggingface/swift-transformers"),
    "swift-jinja": ("Apache 2.0", "https://github.com/huggingface/swift-jinja/blob/main/LICENSE", "https://github.com/huggingface/swift-jinja"),
    
    # MLX packages (MIT)
    "mlx-swift": ("MIT", "https://github.com/ml-explore/mlx-swift/blob/main/LICENSE", "https://github.com/ml-explore/mlx-swift"),
    "mlx-swift-lm": ("MIT", "https://github.com/ml-explore/mlx-swift-lm/blob/main/LICENSE", "https://github.com/ml-explore/mlx-swift-lm"),
    
    # Other packages
    "sparkle": ("MIT", "https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE", "https://github.com/sparkle-project/Sparkle"),
    "fluidaudio": ("Apache 2.0", "https://github.com/FluidInference/FluidAudio/blob/main/LICENSE", "https://github.com/FluidInference/FluidAudio"),
    "swift-sdk": ("MIT", "https://github.com/modelcontextprotocol/swift-sdk/blob/main/LICENSE", "https://github.com/modelcontextprotocol/swift-sdk"),
    "ikigajson": ("MIT", "https://github.com/orlandos-nl/IkigaJSON/blob/master/LICENSE", "https://github.com/orlandos-nl/IkigaJSON"),
    "eventsource": ("MIT", "https://github.com/mattt/EventSource/blob/main/LICENSE", "https://github.com/mattt/EventSource"),
}

# Human-readable names for packages
PACKAGE_NAMES: Dict[str, str] = {
    "swift-nio": "SwiftNIO",
    "swift-atomics": "Swift Atomics",
    "swift-collections": "Swift Collections",
    "swift-log": "Swift Log",
    "swift-numerics": "Swift Numerics",
    "swift-system": "Swift System",
    "swift-argument-parser": "Swift Argument Parser",
    "swift-transformers": "Swift Transformers",
    "swift-jinja": "Swift Jinja",
    "mlx-swift": "MLX Swift",
    "mlx-swift-lm": "MLX Swift LM",
    "sparkle": "Sparkle",
    "fluidaudio": "FluidAudio",
    "swift-sdk": "MCP Swift SDK",
    "ikigajson": "IkigaJSON",
    "eventsource": "EventSource",
}


def parse_package_resolved(path: Path) -> List[Dict]:
    """Parse a Package.resolved file and return list of dependencies."""
    if not path.exists():
        print(f"Warning: {path} not found")
        return []
    
    with open(path, 'r') as f:
        data = json.load(f)
    
    pins = data.get("pins", [])
    return pins


def get_all_dependencies(project_root: Path) -> Dict[str, Dict]:
    """Get all unique dependencies from all Package.resolved files."""
    resolved_files = [
        project_root / "Packages" / "OsaurusCore" / "Package.resolved",
        project_root / "Packages" / "OsaurusCLI" / "Package.resolved",
        project_root / "osaurus.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved",
    ]
    
    dependencies = {}
    
    for resolved_file in resolved_files:
        pins = parse_package_resolved(resolved_file)
        for pin in pins:
            identity = pin.get("identity", "")
            if identity and identity not in dependencies:
                dependencies[identity] = {
                    "identity": identity,
                    "location": pin.get("location", ""),
                    "version": pin.get("state", {}).get("version", pin.get("state", {}).get("revision", "")[:8]),
                }
    
    return dependencies


def generate_acknowledgements(dependencies: Dict[str, Dict]) -> List[Dict]:
    """Generate acknowledgements list from dependencies."""
    acknowledgements = []
    
    for identity, dep in sorted(dependencies.items()):
        license_info = KNOWN_LICENSES.get(identity)
        
        entry = {
            "name": PACKAGE_NAMES.get(identity, identity.replace("-", " ").title()),
            "identity": identity,
            "version": dep.get("version", ""),
            "repository": dep.get("location", license_info[2] if license_info else ""),
            "license": license_info[0] if license_info else "Unknown",
            "licenseUrl": license_info[1] if license_info else "",
        }
        
        acknowledgements.append(entry)
    
    return acknowledgements


def main():
    # Find project root (where this script is in scripts/)
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent
    
    print(f"Project root: {project_root}")
    
    # Get all dependencies
    dependencies = get_all_dependencies(project_root)
    print(f"Found {len(dependencies)} unique dependencies")
    
    # Generate acknowledgements
    acknowledgements = generate_acknowledgements(dependencies)
    
    # Write output
    output = {
        "generated": True,
        "description": "Open source libraries used by Osaurus",
        "acknowledgements": acknowledgements
    }
    
    output_path = project_root / "App" / "osaurus" / "Acknowledgements.json"
    with open(output_path, 'w') as f:
        json.dump(output, f, indent=2)
    
    print(f"Generated {output_path}")
    print(f"Total acknowledgements: {len(acknowledgements)}")
    
    # Print summary
    for ack in acknowledgements:
        print(f"  - {ack['name']} ({ack['license']})")


if __name__ == "__main__":
    main()

