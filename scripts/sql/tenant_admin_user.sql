-- Tenant data server: create the provisioning admin role.
--
-- Run ONCE per environment against the TENANT DATA server (not the registrar's), connected to its
-- `postgres` database, as a superuser or a role with CREATEROLE:
--
--   psql -h <host> -U <superuser> -d postgres -f scripts/sql/tenant_admin_user.sql
--
-- Edit the two values below first. They must match TENANT_DB_ADMIN_USER / TENANT_DB_ADMIN_PASSWORD
-- in the registrar's environment. Safe to re-run: an existing role just has its password and
-- privileges reset to what is configured here.
--
-- The role gets exactly what TenantDatabaseProvisioner needs to provision a tenant, and no more:
--   CREATEDB    - CREATE DATABASE <tenant> OWNER <tenant role>
--   CREATEROLE  - CREATE ROLE / ALTER ROLE ... PASSWORD for each tenant login role, and
--                 GRANT <tenant role> TO <admin> (allowed for roles it created, Postgres 16+)
-- It is NOT a superuser, so it cannot read tenant data; it only reaches the databases it is
-- explicitly granted CONNECT on, which the provisioner does per tenant.
--
-- Postgres 16+ is required (the provisioner relies on its CREATEROLE semantics).

DO
$$
    DECLARE
        -- ---- EDIT ME ------------------------------------------------------------------------
        admin_user     constant text := 'tenantos-tenant-admin';
        admin_password constant text := 'change_me';
        -- -------------------------------------------------------------------------------------
    BEGIN
        IF admin_password = 'CHANGE_ME' THEN
            RAISE EXCEPTION 'Set admin_password at the top of this script before running it';
        END IF;

        IF current_database() <> 'postgres' THEN
            RAISE EXCEPTION 'Run this connected to the postgres database, not %', current_database();
        END IF;

        IF current_setting('server_version_num')::int < 160000 THEN
            RAISE EXCEPTION 'Postgres 16 or newer is required, this is %', current_setting('server_version');
        END IF;

        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = admin_user) THEN
            EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', admin_user, admin_password);
            RAISE NOTICE 'Created role %', admin_user;
        ELSE
            RAISE NOTICE 'Role % already exists, resetting its password and attributes', admin_user;
        END IF;

        -- Converge on a known state whether the role was just created or already existed.
        EXECUTE format(
                'ALTER ROLE %I WITH LOGIN NOSUPERUSER CREATEDB CREATEROLE NOREPLICATION PASSWORD %L',
                admin_user, admin_password);

        -- The admin dials `postgres` to issue CREATE DATABASE. A stock server already lets every
        -- role connect to it; this makes the grant explicit so it survives if the cluster is later
        -- hardened with REVOKE CONNECT ON DATABASE postgres FROM PUBLIC.
        EXECUTE format('GRANT CONNECT ON DATABASE postgres TO %I', admin_user);
    END
$$;
