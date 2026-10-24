#!/usr/bin/env python3
"""Generate the AI Helm repository page without changing the root repository.

Run with uv run --with pyyaml --with packaging ai/scripts/generate_index.py
ai/index.yaml --output ai/index.html.
"""
import argparse
from datetime import datetime
from html import escape
from pathlib import Path

import yaml
from packaging.version import Version


# Only these products appear on the page, in this order. The first value must
# match the chart name in index.yaml; the second is the visible product name.
PRODUCTS = (
    ('redis-agent-memory', 'Redis Agent Memory'),
    ('redis-agent-playbook', 'Redis Agent Playbook'),
    ('iris-identity-service', 'Iris Identity Service'),
    ('redis-iris-onprem-lib', 'Redis Iris On-Premises Library'),
)


def generate_index_html(index_data: dict) -> str:
    """Render published products from PRODUCTS as independent tab panels."""
    entries = index_data.get('entries', {})
    products = [(name, label) for name, label in PRODUCTS if entries.get(name)]
    if not products:
        raise ValueError('The Helm index has no published products from PRODUCTS')
    sections = []
    tabs = []
    for product_position, (name, label) in enumerate(products):
        versions = entries[name]
        versions = sorted(versions, key=lambda item: Version(item['version']), reverse=True)
        latest = versions[0]
        chart = escape(name, quote=True)
        product_name = escape(label)
        active = product_position == 0
        selected_tab = 'true' if active else 'false'
        tab_index = '0' if active else '-1'
        panel_hidden = '' if active else 'hidden'
        tabs.append(f'''<button type="button" role="tab" id="tab-{chart}"
            aria-controls="{chart}" aria-selected="{selected_tab}" tabindex="{tab_index}"
            onclick="selectProduct(this)" onkeydown="navigateProducts(event)">{product_name}</button>''')
        rows = []
        for position, item in enumerate(versions):
            chart_version = escape(str(item['version']), quote=True)
            application_version = escape(str(item.get('appVersion', '')), quote=True)
            command = escape(f"helm install {name} redis-ai/{name} --version {item['version']}", quote=True)
            created = datetime.fromisoformat(item['created'].replace('Z', '+00:00')).date()
            download = escape(item['urls'][0], quote=True)
            digest = escape(item['digest'][:8])
            selected = 'checked' if position == 0 else ''
            latest_class = ' latest-version' if position == 0 else ''
            badge = '<span class="latest-badge">Latest</span>' if position == 0 else ''
            rows.append(f'''<tr class="version-row{latest_class}" data-version="{chart_version}"
                data-appversion="{application_version}" data-command="{command}">
                <td><input type="radio" name="version-{chart}" {selected}
                    onchange="selectVersion(this)">{chart_version} {badge}</td>
                <td>{application_version}</td><td>{created}</td><td>{digest}</td>
                <td><a class="download-btn" href="{download}">Download</a></td></tr>''')
        installation = escape(f"helm install {name} redis-ai/{name} --version {latest['version']}")
        sections.append(f'''<section class="container" id="{chart}" role="tabpanel"
            aria-labelledby="tab-{chart}" tabindex="0" {panel_hidden}>
            <div class="header"><div class="title-section"><h2>{product_name}</h2>
            <p class="description">{escape(latest.get('description', ''))}</p></div></div>
            <div class="metadata"><div>Type: {escape(latest.get('type', 'application'))}</div>
            <div>Latest: {escape(str(latest['version']))}</div></div>
            <div class="installation"><h3>Installation</h3>
            <pre class="command"><code>{installation}</code><button class="copy-btn" onclick="copyCommand(this)">Copy</button></pre></div>
            <div class="search-section"><label>Search versions
            <input type="text" placeholder="Chart or application version" oninput="filterVersions(this.closest('section'))"></label>
            <label><input type="checkbox" onchange="filterVersions(this.closest('section'))">Latest only</label></div>
            <div class="table-scroll"><table class="versions-table"><thead><tr><th>Version</th>
            <th>App Version</th><th>Created</th><th>Digest</th><th>Download</th></tr></thead>
            <tbody>{''.join(rows)}</tbody></table></div></section>''')
    navigation = '<div class="product-tabs" role="tablist" aria-label="Products">' + ''.join(tabs) + '</div>'
    return HEADER + navigation + ''.join(sections) + FOOTER


HEADER = '''<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Redis AI Helm Charts</title><style>
        body {
            font-family: -apple-system, system-ui, sans-serif;
            line-height: 1.5;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background: #f5f5f5;
        }
        .container {
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .header {
            display: flex;
            align-items: center;
            gap: 20px;
            margin-bottom: 30px;
        }
        .chart-icon {
            width: 64px;
            height: 64px;
        }
        .title-section h1 {
            margin: 0;
            color: #2a2a2a;
        }
        .description {
            color: #666;
            margin: 10px 0;
        }
        .metadata {
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
            margin: 20px 0;
            padding: 15px;
            background: #f8f8f8;
            border-radius: 6px;
        }
        .metadata div {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .metadata div::before {
            content: "•";
            color: #666;
        }
        .search-section {
            margin: 20px 0;
            display: flex;
            gap: 10px;
        }
        input[type="text"] {
            padding: 8px 12px;
            border: 1px solid #ddd;
            border-radius: 4px;
            font-size: 14px;
            flex: 1;
        }
        .versions-table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        .versions-table th {
            text-align: left;
            padding: 12px;
            background: #f0f0f0;
            border-bottom: 2px solid #ddd;
        }
        .versions-table td {
            padding: 12px;
            border-bottom: 1px solid #eee;
        }
        .download-btn {
            display: inline-block;
            padding: 6px 12px;
            background: #0366d6;
            color: white;
            text-decoration: none;
            border-radius: 4px;
            font-size: 14px;
        }
        .download-btn:hover {
            background: #0255b3;
        }
        .installation {
            margin-top: 30px;
            padding: 20px;
            background: #f8f8f8;
            border-radius: 6px;
        }
        .command {
            background: #2a2a2a;
            color: white;
            padding: 15px;
            border-radius: 4px;
            font-family: monospace;
            margin: 10px 0;
            position: relative;
        }
        .copy-btn {
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
        }
        .copy-btn:hover {
            background: #555;
        }
        .hidden {
            display: none;
        }
        .latest-version {
            background-color: #f8f8ff;
        }
        .latest-badge {
            background-color: #0366d6;
            color: white;
            padding: 2px 6px;
            border-radius: 12px;
            font-size: 12px;
            margin-left: 8px;
        }
        tr.latest-version td {
            font-weight: 500;
        }
        .version-controls {
            display: flex;
            align-items: center;
            gap: 10px;
            margin-bottom: 10px;
        }
        .toggle-latest {
            padding: 6px 12px;
            background: #f0f0f0;
            border: 1px solid #ddd;
            border-radius: 4px;
            cursor: pointer;
        }
        .toggle-latest:hover {
            background: #e5e5e5;
        }

.container { margin-bottom: 24px; }
.product-tabs { display: flex; gap: 8px; overflow-x: auto; padding: 8px 2px; margin: 24px 0 12px; }
.product-tabs button { flex-shrink: 0; border: 1px solid #ddd; border-radius: 6px; padding: 12px 16px; background: white; color: #333; font: inherit; cursor: pointer; }
.product-tabs button[aria-selected="true"] { background: #0366d6; color: white; border-color: #0366d6; }
.product-tabs button:focus-visible { outline: 3px solid #2a2a2a; outline-offset: 2px; }
.command { white-space: pre-wrap; overflow-wrap: anywhere; padding-right: 70px; }
.table-scroll { overflow-x: auto; }
.search-section { flex-wrap: wrap; align-items: center; }
</style></head><body><h1>Redis AI Helm Charts</h1>
<p>Add this Helm repository:</p>
<pre class="command"><code>helm repo add redis-ai https://helm.redis.io/ai</code><button class="copy-btn" onclick="copyCommand(this)">Copy</button></pre>
'''

FOOTER = '''
<script>
function selectProduct(selectedTab) {
    for (const tab of document.querySelectorAll('[role="tab"]')) {
        const active = tab === selectedTab;
        tab.setAttribute('aria-selected', String(active));
        tab.tabIndex = active ? 0 : -1;
        document.getElementById(tab.getAttribute('aria-controls')).hidden = !active;
    }
}
function navigateProducts(event) {
    const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
    let position = tabs.indexOf(event.currentTarget);
    if (event.key === 'ArrowRight') position = (position + 1) % tabs.length;
    else if (event.key === 'ArrowLeft') position = (position - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') position = 0;
    else if (event.key === 'End') position = tabs.length - 1;
    else return;
    event.preventDefault();
    selectProduct(tabs[position]);
    tabs[position].focus();
}
function filterVersions(section) {
    const search = section.querySelector('input[type="text"]').value.toLowerCase();
    const latestOnly = section.querySelector('input[type="checkbox"]').checked;
    for (const row of section.querySelectorAll('.version-row')) {
        const matches = row.dataset.version.toLowerCase().includes(search) ||
            row.dataset.appversion.toLowerCase().includes(search);
        row.hidden = !matches || (latestOnly && !row.classList.contains('latest-version'));
    }
}
function selectVersion(radio) {
    radio.closest('section').querySelector('.command code').textContent =
        radio.closest('tr').dataset.command;
}
async function copyCommand(button) {
    await navigator.clipboard.writeText(button.parentElement.querySelector('code').textContent);
    button.textContent = 'Copied!';
    setTimeout(() => { button.textContent = 'Copy'; }, 2000);
}
</script></body></html>
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('index_file', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.name != 'index.html' or arguments.output.parent.name != 'ai':
        parser.error('Output must be ai/index.html to protect the root repository page')
    index_data = yaml.safe_load(arguments.index_file.read_text())
    arguments.output.write_text(generate_index_html(index_data), encoding='utf-8')
    print(f'Generated {arguments.output}')


if __name__ == '__main__':
    main()
