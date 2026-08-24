---
date: 2026-08-24
issue: 1046
title: Keep the component contract fixture free of SIGPIPE races
---

Pin the component release integration fixture to the canonical contract that removed captured-value producer pipelines, so its repeated `pipefail` checks report the real contract violation instead of a misleading Node-version failure.
