mock_provider "hcloud" {}

variables {
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPXA+Se9/Qe0smsGG1zAi28RxCeYIAKnJFwYUG1Z/Ctn test@devbox"
  disk_size      = 0
}

run "default_plan" {
  command = plan

  assert {
    condition     = can(regex("DEVBOX_USER=\"dev\"", module.core.user_data))
    error_message = "user_data must contain DEVBOX_USER"
  }

  assert {
    condition     = can(regex("INSTALL_DOCKER=\"true\"", module.core.user_data))
    error_message = "user_data must contain INSTALL_DOCKER"
  }

  assert {
    condition     = can(regex("INSTALL_CODEX=\"true\"", module.core.user_data))
    error_message = "user_data must contain INSTALL_CODEX"
  }

  assert {
    condition     = can(regex("INSTALL_CLAUDE=\"true\"", module.core.user_data))
    error_message = "user_data must contain INSTALL_CLAUDE"
  }

  assert {
    condition     = can(regex("INSTALL_OPENCODE=\"false\"", module.core.user_data))
    error_message = "user_data must contain INSTALL_OPENCODE"
  }

  assert {
    condition     = can(regex("INSTALL_ANTIGRAVITY=\"true\"", module.core.user_data))
    error_message = "user_data must contain INSTALL_ANTIGRAVITY"
  }

  assert {
    condition     = can(regex("INSTALL_BROWSER=\"true\"", module.core.user_data))
    error_message = "user_data must contain INSTALL_BROWSER"
  }

  assert {
    condition     = !can(regex("runner-key", module.core.user_data))
    error_message = "runner_ssh_public_key should not be in user_data when empty"
  }
}

run "tailscale_no_cidr_closes_ssh" {
  command = plan

  variables {
    tailscale_authkey = "tskey-auth-12345678"
    ssh_allowed_cidrs = null
  }

  assert {
    condition     = length(module.core.ssh_cidrs) == 0
    error_message = "ssh_cidrs must be empty when tailscale_authkey is set without ssh_allowed_cidrs"
  }

  assert {
    condition     = length([for r in hcloud_firewall.this.rule : r if r.description == "SSH"]) == 0
    error_message = "port 22 rule must not be present when tailscale is configured without CIDRs"
  }
}

run "runner_key_included_when_set" {
  command = plan

  variables {
    runner_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRunnerEphemeralKeyForTesting123456789 runner@ci"
  }

  assert {
    condition     = can(regex("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRunnerEphemeralKeyForTesting123456789 runner@ci", module.core.user_data))
    error_message = "runner_ssh_public_key must be present in user_data when non-empty"
  }
}

run "payload_ref_reaches_trigger" {
  command = plan

  variables {
    git_ref = "test-payload-ref-1234"
  }

  assert {
    condition     = can(regex("test-payload-ref-1234", terraform_data.payload.input))
    error_message = "payload_ref/git_ref must reach the terraform_data trigger"
  }

  assert {
    condition     = startswith(terraform_data.payload.input, "${var.git_ref}:${var.server_type}:")
    error_message = "terraform_data payload trigger must start with git_ref:server_type to match main"
  }
}
