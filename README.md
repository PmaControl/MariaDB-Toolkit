# MariaDB Toolkit

`mariadb_storage_audit.sh` audits and tunes Linux system settings around MariaDB/MySQL.

## Features

- read-only audit mode
- dry-run mode showing commands that would be executed
- apply mode for Linux system tuning
- multilingual help: `fr`, `en`, `ru`, `zh`
- installable man page: `man mariadb_storage_audit`

## Commands

```bash
./mariadb_storage_audit.sh --check
./mariadb_storage_audit.sh --dry-run
./mariadb_storage_audit.sh --apply
./mariadb_storage_audit.sh --help --lang en
./mariadb_storage_audit.sh --install-man
```

## Scope

The script applies Linux system settings only. It may read MariaDB values for diagnostics, but it does not modify MariaDB configuration.

## License

GPL-v3. See `LICENSE`.

## Contributing

Run the local checks before committing:

```bash
./tests/run-shellcheck.sh
bats tests/mariadb_storage_audit.bats
```

Install the versioned pre-commit hook:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit tests/run-shellcheck.sh
```

The hook runs `shellcheck` and `bats` before each commit.

## Author

Aurélien LEQUOY  
<aurelien@pmacontrol.com>  
http://www.pmacontrol.com
