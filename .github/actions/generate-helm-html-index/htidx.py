#!/usr/bin/env python3
"""
Helm Chart Repository Index Generator

This script generates a clean, searchable HTML index page from a Helm chart
repository's index.yaml file. It creates a modern, responsive webpage that
displays chart information and allows users to search through available
versions.
"""
import argparse
import os
import sys
from datetime import datetime

import yaml


def read_index_yaml(file_path: str) -> dict:
    """
    Read and parse the index.yaml file.

    Args:
        file_path: Path to the index.yaml file

    Returns:
        Dictionary containing the parsed YAML data
    """
    with open(file_path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


def format_date(date_str: str) -> str:
    """
    Convert ISO date string to readable format.

    Args:
        date_str: ISO format date string

    Returns:
        Formatted date string in YYYY-MM-DD format
    """
    try:
        return datetime.strptime(date_str,
                                 "%Y-%m-%dT%H:%M:%S.%fZ").strftime("%Y-%m-%d")
    except ValueError:
        pass
    try:
        return datetime.strptime(date_str,
                                 "%Y-%m-%dT%H:%M:%SZ").strftime("%Y-%m-%d")
    except ValueError:
        base_dt = date_str.split('.')
        if len(base_dt) == 2:
            micro = base_dt[1].replace('Z', '')[:6]
            date_str = f"{base_dt[0]}.{micro}Z"
            return datetime.strptime(
                date_str, "%Y-%m-%dT%H:%M:%S.%fZ").strftime("%Y-%m-%d")
        raise


def generate_version_rows(chart_name: str, versions: list) -> str:
    """
    Generate HTML table rows for chart versions.

    Args:
        chart_name: Name of the Helm chart
        versions: List of version dictionaries from index.yaml

    Returns:
        HTML string containing table rows for each version
    """
    rows = []

    default_cmd = f"helm install redis-operator redis/{chart_name}"
    latest_version = versions[0]['version']

    for v in versions:
        created_date = format_date(v["created"])
        cmd = f"helm install redis-operator redis/{chart_name} --version {v['version']}"
        is_latest = v['version'] == latest_version
        latest_badge = ""
        checked = ""
        lst_version = ""
        if is_latest:
            checked = "checked"
            lst_version = ' latest-version'
            latest_badge = '<span class="latest-badge">Latest</span>'

        rows.append(f'''
        <tr class="version-row{lst_version}"
            data-version="{v['version']}"
            data-appversion="{v['appVersion']}"
            data-command="{cmd}">
            <td>
                <input type="radio" name="version" value="{v['version']}"
                    onclick="toggleVersion(this)" data-default="{default_cmd}" {checked}>
                {v['version']} {latest_badge}
            </td>
            <td>{v['appVersion']}</td>
            <td>{created_date}</td>
            <td>{v['digest'][:8]}</td>
            <td><a href="{v['urls'][0]}" class="download-btn">Download</a></td>
        </tr>''')
    return '\n'.join(rows)


def generate_index_html(index_data: dict, repo_url: str) -> str:
    """
    Generate the complete HTML index page.

    Args:
        index_data: Parsed index.yaml data
        repo_url: URL of the Helm repository

    Returns:
        Complete HTML page as a string
    """
    chart_name = next(iter(index_data['entries']))
    display_name = chart_name.replace('-', ' ').title()

    versions = index_data['entries'][chart_name]
    versions.sort(key=lambda x: x['created'], reverse=True)
    latest = versions[0]
    version_rows = generate_version_rows(chart_name, versions)
    initial_install_cmd = f"helm install redis-operator redis/{chart_name} --version {latest['version']}"

    return f'''<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{display_name} - Helm Chart</title>
    <style>
        body {{
            font-family: -apple-system, system-ui, sans-serif;
            line-height: 1.5;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background: #f5f5f5;
        }}
        .container {{
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        .header {{
            display: flex;
            align-items: center;
            gap: 20px;
            margin-bottom: 30px;
        }}
        .chart-icon {{
            width: 64px;
            height: 64px;
        }}
        .title-section h1 {{
            margin: 0;
            color: #2a2a2a;
        }}
        .description {{
            color: #666;
            margin: 10px 0;
        }}
        .metadata {{
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
            margin: 20px 0;
            padding: 15px;
            background: #f8f8f8;
            border-radius: 6px;
        }}
        .metadata div {{
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .metadata div::before {{
            content: "•";
            color: #666;
        }}
        .search-section {{
            margin: 20px 0;
            display: flex;
            gap: 10px;
        }}
        input[type="text"] {{
            padding: 8px 12px;
            border: 1px solid #ddd;
            border-radius: 4px;
            font-size: 14px;
            flex: 1;
        }}
        .versions-table {{
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }}
        .versions-table th {{
            text-align: left;
            padding: 12px;
            background: #f0f0f0;
            border-bottom: 2px solid #ddd;
        }}
        .versions-table td {{
            padding: 12px;
            border-bottom: 1px solid #eee;
        }}
        .download-btn {{
            display: inline-block;
            padding: 6px 12px;
            background: #0366d6;
            color: white;
            text-decoration: none;
            border-radius: 4px;
            font-size: 14px;
        }}
        .download-btn:hover {{
            background: #0255b3;
        }}
        .installation {{
            margin-top: 30px;
            padding: 20px;
            background: #f8f8f8;
            border-radius: 6px;
        }}
        .command {{
            background: #2a2a2a;
            color: white;
            padding: 15px;
            border-radius: 4px;
            font-family: monospace;
            margin: 10px 0;
            position: relative;
        }}
        .copy-btn {{
            position: absolute;
            right: 5px;
            top: 5px;
            padding: 5px 10px;
            background: #444;
            border: none;
            color: white;
            border-radius: 3px;
            cursor: pointer;
            font-size: 12px;
        }}
        .copy-btn:hover {{
            background: #555;
        }}
        .hidden {{
            display: none;
        }}
        .latest-version {{
            background-color: #f8f8ff;
        }}
        .latest-badge {{
            background-color: #0366d6;
            color: white;
            padding: 2px 6px;
            border-radius: 12px;
            font-size: 12px;
            margin-left: 8px;
        }}
        tr.latest-version td {{
            font-weight: 500;
        }}
        .version-controls {{
            display: flex;
            align-items: center;
            gap: 10px;
            margin-bottom: 10px;
        }}
        .toggle-latest {{
            padding: 6px 12px;
            background: #f0f0f0;
            border: 1px solid #ddd;
            border-radius: 4px;
            cursor: pointer;
        }}
        .toggle-latest:hover {{
            background: #e5e5e5;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            {f'<img src="{latest["icon"]}" class="chart-icon" alt="{chart_name}">'
              if 'icon' in latest else ''}
            <div class="title-section">
                <h1>{display_name}</h1>
                <div class="description">{latest['description']}</div>
            </div>
        </div>
        <div class="metadata">
            <div>Type: {latest['type']}</div>
            <div>Latest: v{latest['version']}</div>
            <div>App Version: {latest['appVersion']}</div>
            {f'<div>Home: <a href="{latest["home"]}">{latest["home"]}</a></div>'
              if 'home' in latest else ''}
        </div>
        <div class="installation">
            <h3>Installation</h3>
            <p>Add this Helm repository:</p>
            <div class="command">
                $ helm repo add redis {repo_url}
                <button class="copy-btn" onclick="copyCommand(this)">Copy</button>
            </div>
            <p>Install the chart:</p>
            <div class="command" id="install-command">
                $ {initial_install_cmd}
                <button class="copy-btn" onclick="copyCommand(this)">Copy</button>
            </div>
        </div>
        <div class="search-section">
            <div class="version-controls">
                <button class="toggle-latest" onclick="toggleLatestVersion()">
                    Show/Hide Other Versions
                </button>
            </div>
            <input type="text" id="versionSearch"
                   placeholder="Search versions (e.g., 0.2 or 7.4)..."
                   onkeyup="filterVersions()">
        </div>
        <table class="versions-table">
            <thead>
                <tr>
                    <th>Version</th>
                    <th>App Version</th>
                    <th>Created</th>
                    <th>Digest</th>
                    <th>Download</th>
                </tr>
            </thead>
            <tbody>
                {version_rows}
            </tbody>
        </table>
    </div>
<script>
    let showOnlyLatest = false;

    function toggleLatestVersion() {{
        showOnlyLatest = !showOnlyLatest;
        const rows = document.getElementsByClassName('version-row');
        for (const row of rows) {{
            if (!row.classList.contains('latest-version')) {{
                row.classList.toggle('hidden', showOnlyLatest);
            }}
        }}
    }}

    function filterVersions() {{
        const searchText = document.getElementById('versionSearch').value
            .toLowerCase();
        const rows = document.getElementsByClassName('version-row');
        for (const row of rows) {{
            const version = row.dataset.version.toLowerCase();
            const appVersion = row.dataset.appversion.toLowerCase();
            if (showOnlyLatest && !row.classList.contains('latest-version')) {{
                row.classList.add('hidden');
                continue;
            }}
            const matches = version.includes(searchText) ||
                          appVersion.includes(searchText);
            row.classList.toggle('hidden', !matches);
        }}
    }}


    function toggleVersion(radio) {{
        // Always update the command when a radio is clicked
        const row = radio.closest('tr');
        const command = row.dataset.command;
        updateInstallCommand(command);
    }}


    function updateInstallCommand(command) {{
        const commandDiv = document.getElementById('install-command');
        commandDiv.textContent = '$ ' + command;
        const copyBtn = document.createElement('button');
        copyBtn.className = 'copy-btn';
        copyBtn.onclick = function() {{ copyCommand(this); }};
        copyBtn.textContent = 'Copy';
        commandDiv.appendChild(copyBtn);
    }}

    function copyCommand(button) {{
        const command = button.parentElement.textContent.trim()
            .replace('Copy', '')
            .replace('$', '')
            .trim();
        navigator.clipboard.writeText(command);
        const originalText = button.textContent;
        button.textContent = 'Copied!';
        setTimeout(() => {{
            button.textContent = originalText;
        }}, 2000);
    }}

    document.addEventListener('DOMContentLoaded', function() {{
        const radio = document.querySelector('input[type="radio"][checked]');
        if (radio) {{
            const row = radio.closest('tr');
            const command = row.dataset.command;
            updateInstallCommand(command);
        }}
    }});
</script>
</body>
</html>'''


def main() -> int:
    """
    Main function that processes command line arguments and generates the index page.

    Returns:
        0 for success, 1 for failure
    """
    parser = argparse.ArgumentParser(
        description='Generate HTML index page from Helm index.yaml')
    parser.add_argument('index_file', help='Path to index.yaml file')
    parser.add_argument('--output',
                        '-o',
                        default='index.html',
                        help='Output HTML file path')
    parser.add_argument('--repo-url',
                        default='https://helm.redis.io',
                        help='Repository URL')
    args = parser.parse_args()

    if not os.path.exists(args.index_file):
        print(f"Error: Index file not found: {args.index_file}")
        return 1

    index_data = read_index_yaml(args.index_file)
    if not index_data or 'entries' not in index_data or not index_data[
            'entries']:
        print("Error: No entries found in index.yaml")
        return 1

    html_content = generate_index_html(index_data, args.repo_url)
    if not html_content:
        print("Error: Failed to generate HTML content")
        return 1

    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(html_content)
    print(f"Generated index page at: {args.output}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
