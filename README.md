# carpentry

A website for the carpentry collective.

<hr/>

Have fun!

## Deploying

`libs.tsv` is the list of packages: name, repo, route, category, blurb. A route
of `-` means the package is listed but not hosted here, so the landing page
links to GitHub instead; a route can also be a full URL, for a package whose
docs its maintainer hosts elsewhere.

`deploy.sh` rebuilds every hosted package from its latest tag and publishes the
result, so the site converges on the tags rather than accumulating whatever was
copied up by hand:

```sh
./deploy.sh check              # validate the manifest against GitHub
./deploy.sh build              # generate the whole site into ./site
./deploy.sh build json semver  # ... or just some routes
./deploy.sh deploy             # build, then rsync to the server
```

A package that fails to build is reported and skipped, and its live docs are
left untouched; the run then exits nonzero. Docs are generated, never taken
from a committed `docs/` directory, so packages do not need to commit theirs.

CI runs `deploy` nightly. To publish a release immediately:

```sh
gh workflow run deploy.yml -R hellerve/website
```

### Server

The deploy user only needs to write into the document root, so its key is
restricted to exactly that in `~/.ssh/authorized_keys`:

```
restrict,command="rrsync -wo /var/www/html/carpentry" ssh-ed25519 AAAA...
```

`rrsync` ships with rsync and confines the session to that subtree; `-wo` makes
it write-only. With that forced command in place the repository variable
`CARPENTRY_DEST` is `carpentry-docs@veitheller.de:/`, since rrsync resolves
paths inside its own root. The private half of the key is the repository secret
`CARPENTRY_DEPLOY_KEY`, and `CARPENTRY_KNOWN_HOSTS` pins the host key.
