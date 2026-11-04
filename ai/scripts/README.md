# AI Helm repository page

The AI release workflow generates `ai/index.html` from the published
`ai/index.yaml` after updating the chart index, then deploys the entire Pages
branch. Products appear as tabs, each with its own version selection, search,
and install command. Switch tabs with a click or the arrow, Home, and End keys.

Edit `PRODUCTS` in `generate_index.py` to control which products appear, their
display names, and their tab order. Each entry pairs a chart name from
`index.yaml` with a display name. The list covers the Redis Iris global chart
and all its products: Agent Memory, Agent Playbook, Lens, Context Gateway,
Intent Router, Identity Service, and the Iris user interface. It also retains
the Redis Iris On-Premises Library. Keep this list aligned with the dependencies
in [the Iris global chart](https://github.com/redislabsdev/iris/blob/main/iris/helm/Chart.yaml).
Unlisted charts stay off the page; listed charts without published versions
are skipped and appear automatically once published. Generation fails if no listed products are published.
The root page and operator release workflow are independent.

To preview using a local checkout of the `gh-pages` branch:

```bash
uv run --python 3.12 --with pyyaml --with packaging \
  ai/scripts/generate_index.py /path/to/pages/ai/index.yaml \
  --output /path/to/pages/ai/index.html
```

To generate a page without releasing a chart, open **Actions → Generate AI Helm
Repository Page → Run workflow**. Keep **Use workflow from** set to `master`,
then set the **branch** input to the generator branch in this repository:

- `master`: regenerate and publish the live page. The workflow commits only
  `ai/index.html` when it changes, then deploys the entire Pages branch. It also
  deploys when the page is unchanged, so rerunning can recover a failed deployment.
- Any other branch: generate a preview with read-only repository permissions.
  Download `ai-helm-page-preview` from the run's artifacts, extract it, and open
  `index.html` locally. Preview runs do not push or deploy.

Both modes use the published `gh-pages/ai/index.yaml`. The branch input accepts
branch names in this repository, not tags, commit identifiers, or fork branches.
The manual **Run workflow** button becomes available after merging into `master`.

```bash
# Publish using master.
gh workflow run generate-ai-page.yaml --repo RedisLabs/redis-enterprise-helm --ref master -f branch=master

# Preview a feature branch.
gh workflow run generate-ai-page.yaml --repo RedisLabs/redis-enterprise-helm --ref master -f branch=my-feature
```

Pull requests from branches in this repository targeting `master` automatically
produce the same preview when they change `ai/scripts/**` or this workflow.
The preview uses the pull request's exact head commit and the published chart
index. Fork pull requests are skipped. Publication and deployment are always
skipped for pull request runs.

To test before merging:

1. Push the generator or workflow changes to your pull request branch.
2. Open the pull request's **Checks** tab and select **Generate AI Helm Repository
   Page / preview**, then open the workflow run summary.
3. Download **ai-helm-page-preview** from **Artifacts**, extract it, and open
   `index.html` in your browser.
4. Check the product tabs, version selection, search, and installation commands.
   Confirm that **generate-page** and **deploy** were skipped in the run.

AI chart releases continue to regenerate and publish the page automatically.
If another publisher updates `gh-pages` during generation, the push fails safely;
rerun the workflow to regenerate from the latest published index.

Live refreshes and chart releases do not share a deployment lock. Avoid running
a live refresh during a chart release: overlapping deployments can publish an
older site snapshot. Preview runs do not deploy and are unaffected.
