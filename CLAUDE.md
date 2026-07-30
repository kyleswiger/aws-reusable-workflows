# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is
This repository holds **Reusable GitHub Actions workflows** (`workflow_call`). It is designed to be public, abstracting CI/CD logic away from proprietary backend repos (e.g., `sportscard-intelligence`).

## Architecture & Tenets
- **No Hardcoded Secrets:** Workflows must expect secrets to be passed in from the caller (e.g., `secrets: inherit` or explicit `inputs`).
- **OIDC Authentication:** AWS access must rely on `aws-actions/configure-aws-credentials` using GitHub OIDC, never long-lived access keys.
- **Agentic Reviews:** Pull Request workflows should integrate AI review steps (e.g., Claude/Gemini) automatically for consuming repositories.

## Future Master Plan
We are decoupling CI/CD away from AWS CodeBuild into pure GitHub Actions.
This repository will host the canonical `deploy.yml`, `pr-preview.yml`, and `lint.yml` for all of Kyle's projects.
