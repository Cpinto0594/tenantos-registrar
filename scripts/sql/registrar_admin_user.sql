-- Registrar database: create the role the registrar application connects as.
--
-- Run ONCE per environment, connected to the REGISTRAR database (e.g. tenantos_registrar), as a
-- superuser or a role with CREATEROLE that can also grant on the database:
--
--   psql -h <host> -U <superuser> -d tenantos_registrar -f scripts/sql/registrar_admin_user.sql
--
-- Edit the three values below first. They must match POSTGRES_USER / POSTGRES_PASSWORD in the
-- registrar's environment. Safe to re-run: an existing role just has its password and
-- privileges reset to what is configured here.
--
-- The role is NOT a superuser. It can log in, and can create and modify objects in the registrar
-- database - which is what Flyway (src/main/resources/db/migration) and the app itself need.

DO
$$
    DECLARE
        -- ---- EDIT ME ------------------------------------------------------------------------
        admin_user     constant text := 'tenantos-master';
        admin_password constant text := 'CHANGE_ME';
        -- Hand the role ownership of tables/sequences/views that ALREADY exist in `public` and
        -- belong to someone else (e.g. created earlier by a superuser or a previous app role).
        -- Needed if this role runs Flyway: ALTER TABLE in later migrations requires ownership,
        -- and a grant alone is not enough. Set to false to only grant read/write access.
        take_ownership constant boolean := true;
        -- -------------------------------------------------------------------------------------
        db_name        constant text := current_database();
        obj            record;
    BEGIN
        IF admin_password = 'CHANGE_ME' THEN
            RAISE EXCEPTION 'Set admin_password at the top of this script before running it';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = admin_user) THEN
            EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', admin_user, admin_password);
            RAISE NOTICE 'Created role %', admin_user;
        ELSE
            RAISE NOTICE 'Role % already exists, resetting its password and attributes', admin_user;
        END IF;

        -- Converge on a known state whether the role was just created or already existed.
        EXECUTE format(
                'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L',
                admin_user, admin_password);

        -- CONNECT + CREATE (schemas) + TEMP on this database; full control of the public schema.
        EXECUTE format('GRANT ALL ON DATABASE %I TO %I', db_name, admin_user);
        EXECUTE format('GRANT ALL ON SCHEMA public TO %I', admin_user);

        -- Objects that already exist. Default privileges below only cover FUTURE objects, so
        -- without this every table created before this script ran (e.g. by an earlier role) is
        -- off limits: "permission denied for table tenant_workspace_provisioning".
        EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA public TO %I', admin_user);
        EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO %I', admin_user);

        IF take_ownership THEN
            -- Skips sequences owned by a column (they follow their table) and extension members.
            FOR obj IN
                SELECT c.relname
                FROM pg_class c
                         JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'public'
                  AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
                  AND c.relowner <> (SELECT oid FROM pg_roles WHERE rolname = admin_user)
                  AND NOT EXISTS (SELECT 1
                                  FROM pg_depend d
                                  WHERE d.classid = 'pg_class'::regclass
                                    AND d.objid = c.oid
                                    AND d.deptype IN ('a', 'i', 'e'))
                ORDER BY c.relkind = 'S', c.relname -- tables first, standalone sequences last
                LOOP
                    EXECUTE format('ALTER TABLE public.%I OWNER TO %I', obj.relname, admin_user);
                    RAISE NOTICE 'Transferred ownership of public.% to %', obj.relname, admin_user;
                END LOOP;
        END IF;

        -- Objects created later by other roles (e.g. a DBA running a migration by hand) stay
        -- usable by the application role.
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO %I', admin_user);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO %I', admin_user);
    END
$$;
