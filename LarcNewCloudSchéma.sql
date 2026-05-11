--
-- PostgreSQL database dump
--

\restrict TiEVmZXggUzogKp4cje0Z8w6FzXbfXUL3kxLpuQkc97dbvjPmdcpUXiUokBUBS2

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.2

-- Started on 2026-05-05 12:22:11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 28 (class 2615 OID 2200)
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA public;


ALTER SCHEMA public OWNER TO pg_database_owner;

--
-- TOC entry 4642 (class 0 OID 0)
-- Dependencies: 28
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- TOC entry 1213 (class 1247 OID 17404)
-- Name: status_acquisition_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.status_acquisition_type AS ENUM (
    'NA',
    'PA',
    'A',
    '-'
);


ALTER TYPE public.status_acquisition_type OWNER TO postgres;

--
-- TOC entry 503 (class 1255 OID 21045)
-- Name: fn_sync_log(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_sync_log() RETURNS trigger
    LANGUAGE plpgsql
    AS $$                                                                                                        
 DECLARE                                                                                                      
     v_cfg        record;                                                                                     
     v_source     text;                                                                                       
     v_old        jsonb;                                                                                      
     v_new        jsonb;                                                                                      
     v_diff_old   jsonb := '{}';                                                                              
     v_diff_new   jsonb := '{}';                                                                              
     v_key        text;                                                                                       
     v_excl       text[] := ARRAY[                                                                            
         'sync_revision', 'sync_origin',                                                                      
         'updated_at', 'last_modified_at',                                                                    
         'synced', 'source'                                                                                   
     ];                                                                                                       
 BEGIN                                                                                                        
     v_source := COALESCE(NULLIF(current_setting('app.sync_source', true), ''), 'intranet');                  
     IF v_source = 'daemon' THEN                                                                              
         RETURN NEW;                                                                                          
     END IF;                                                                                                  
                                                                                                              
     SELECT * INTO v_cfg                                                                                      
     FROM public.sync_table_config                                                                            
     WHERE table_name = TG_TABLE_NAME                                                                         
       AND sync_enabled = true;                                                                               
                                                                                                              
     IF NOT FOUND THEN                                                                                        
         RETURN NEW;                                                                                          
     END IF;                                                                                                  
                                                                                                              
     NEW.sync_revision := COALESCE(OLD.sync_revision, 0) + 1;                                                 
                                                                                                              
     v_old := to_jsonb(OLD);                                                                                  
     v_new := to_jsonb(NEW);                                                                                  
     FOR v_key IN SELECT jsonb_object_keys(v_new) LOOP                                                        
         IF v_old->v_key IS DISTINCT FROM v_new->v_key THEN                                                   
             v_diff_old := v_diff_old || jsonb_build_object(v_key, v_old->v_key);                             
             v_diff_new := v_diff_new || jsonb_build_object(v_key, v_new->v_key);                             
         END IF;                                                                                              
     END LOOP;                                                                                                
                                                                                                              
     v_diff_old := v_diff_old - v_excl;                                                                       
     v_diff_new := v_diff_new - v_excl;                                                                       
                                                                                                              
     INSERT INTO public.sync_log                                                                              
         (sync_level, table_name, record_id, new_revision,                                                    
          modified_by, old_data, new_data, sync_source)                                                       
     VALUES (                                                                                                 
         v_cfg.sync_level,                                                                                    
         TG_TABLE_NAME,                                                                                       
         (to_jsonb(NEW) ->> v_cfg.pk_column),                                                                 
         NEW.sync_revision,                                                                                   
         NULLIF(current_setting('app.modified_by', true), '')::integer,                                       
         v_diff_old,                                                                                          
         v_diff_new,                                                                                          
         v_source                                                                                             
     );                                                                                                       
                                                                                                              
     -- Notification instantanée au daemon (coût : ~microsecondes)                                            
     PERFORM pg_notify(                                                                                       
         'sync_ch_' || v_cfg.sync_level::text,                                                                
         (to_jsonb(NEW) ->> v_cfg.pk_column)                                                                  
     );                                                                                                       
                                                                                                              
     RETURN NEW;                                                                                              
 END;                                                                                                         
 $$;


ALTER FUNCTION public.fn_sync_log() OWNER TO postgres;

--
-- TOC entry 4644 (class 0 OID 0)
-- Dependencies: 503
-- Name: FUNCTION fn_sync_log(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.fn_sync_log() IS 'Trigger générique Double Verrou : incrémente sync_revision + écrit dans sync_log. Lit le niveau et la PK dans sync_table_config. Skip si app.sync_source=daemon (anti-boucle). Pose SET LOCAL app.modified_by=<id> avant chaque UPDATE pour tracer l''auteur.';


--
-- TOC entry 502 (class 1255 OID 20919)
-- Name: fn_track_updates(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_track_updates() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.last_modified_at := CURRENT_TIMESTAMP; -- On marque l'instant précis du changement
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_track_updates() OWNER TO postgres;

--
-- TOC entry 501 (class 1255 OID 18639)
-- Name: handle_sync_log(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.handle_sync_log() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- SÉCURITÉ : Ignorer si c'est la table de log elle-même
    IF TG_TABLE_NAME = 'larcauth_sync_log' THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'DELETE' THEN
        INSERT INTO public.larcauth_sync_log (table_name, operation, old_data)
        VALUES (TG_TABLE_NAME, TG_OP, to_jsonb(OLD));
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD IS DISTINCT FROM NEW THEN
            INSERT INTO public.larcauth_sync_log (table_name, operation, old_data, new_data)
            VALUES (TG_TABLE_NAME, TG_OP, to_jsonb(OLD), to_jsonb(NEW));
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO public.larcauth_sync_log (table_name, operation, new_data)
        VALUES (TG_TABLE_NAME, TG_OP, to_jsonb(NEW));
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION public.handle_sync_log() OWNER TO postgres;

--
-- TOC entry 500 (class 1255 OID 18638)
-- Name: handle_updated_at_and_sync(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.handle_updated_at_and_sync() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated = NOW();
    IF OLD IS DISTINCT FROM NEW THEN
        NEW.sync_version = COALESCE(NEW.sync_version, 0) + 1;
        NEW.synced_at = NOW();
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.handle_updated_at_and_sync() OWNER TO postgres;

--
-- TOC entry 469 (class 1255 OID 17170)
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION public.rls_auto_enable() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 327 (class 1259 OID 17413)
-- Name: larcauth_academicyear; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_academicyear (
    s_id smallint NOT NULL,
    label character varying(9) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    current_term_number smallint NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    auto_calc boolean NOT NULL,
    debug_mode boolean NOT NULL,
    synchro_allowed boolean NOT NULL,
    "Current_unit_number" smallint DEFAULT 1,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_academicyear OWNER TO postgres;

--
-- TOC entry 328 (class 1259 OID 17417)
-- Name: larcauth_aecuser; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_aecuser (
    id integer NOT NULL,
    password character varying(128) NOT NULL,
    last_login timestamp with time zone,
    is_superuser boolean NOT NULL,
    username character varying(150) NOT NULL,
    first_name character varying(30) NOT NULL,
    last_name character varying(150) NOT NULL,
    email character varying(254) NOT NULL,
    is_staff boolean NOT NULL,
    is_active boolean NOT NULL,
    date_joined timestamp with time zone NOT NULL,
    firstname_2 character varying(72),
    date_entree date,
    tel_maison character varying(20),
    tel_smartphone_1 character varying(20),
    tel_smartphone_2 character varying(20),
    emailperso character varying(254),
    passdelph character varying(20),
    avatar character varying(100) NOT NULL,
    picture2 bytea NOT NULL,
    type_parentutor boolean,
    type_teacher boolean,
    type_coordonator boolean,
    type_supervisor boolean,
    type_student boolean,
    type_director boolean,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_gender_id integer,
    fk_parent_id integer,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_aecuser OWNER TO postgres;

--
-- TOC entry 329 (class 1259 OID 17422)
-- Name: larcauth_agenda; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_agenda (
    id integer NOT NULL,
    date_all date NOT NULL,
    j smallint DEFAULT 0 NOT NULL,
    m smallint DEFAULT 0 NOT NULL,
    w smallint DEFAULT 0 NOT NULL,
    year smallint DEFAULT 0 NOT NULL,
    year_week smallint DEFAULT 0,
    term smallint DEFAULT 0,
    term_week smallint DEFAULT 0,
    unit smallint DEFAULT 0,
    unit_week smallint DEFAULT 0,
    working_day boolean DEFAULT true,
    week_day smallint DEFAULT 0,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_agenda OWNER TO postgres;

--
-- TOC entry 330 (class 1259 OID 17436)
-- Name: larcauth_campus; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_campus (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    label character varying(72) NOT NULL,
    adress character varying(255) NOT NULL,
    city character varying(72) NOT NULL,
    country character varying(2) NOT NULL,
    tel_1 character varying(12) NOT NULL,
    tel_2 character varying(12),
    email_1 character varying(254) NOT NULL,
    email_2 character varying(254),
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_district_id integer NOT NULL,
    fk_language_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_campus OWNER TO postgres;

--
-- TOC entry 331 (class 1259 OID 17441)
-- Name: larcauth_classroom; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_classroom (
    id integer NOT NULL,
    label character varying(33) NOT NULL,
    index_in_level smallint NOT NULL,
    description text NOT NULL,
    enabled boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_level_id integer NOT NULL,
    fk_headteacher_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_classroom OWNER TO postgres;

--
-- TOC entry 332 (class 1259 OID 17446)
-- Name: larcauth_classroom_has_timeperiod; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_classroom_has_timeperiod (
    id character varying(12) NOT NULL,
    fk_classroom integer,
    fk_weekday smallint,
    fk_timeperiod character varying,
    fk_term smallint,
    ref_classroom_termsubject integer,
    s_classroom_termsubject character varying(72),
    remarque character varying(255),
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_classroom_has_timeperiod OWNER TO postgres;

--
-- TOC entry 333 (class 1259 OID 17451)
-- Name: larcauth_classroom_termothersubject; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_classroom_termothersubject (
    id integer NOT NULL,
    label character varying(144) NOT NULL,
    description text NOT NULL,
    unit_multisubjects boolean NOT NULL,
    nb_subjects smallint,
    ref_unit_subject1 smallint,
    ref_unit_subject2 smallint,
    ref_unit_subject3 smallint,
    ref_unit_subject4 smallint,
    ref_unit_subject5 smallint,
    ref_unit_subject6 smallint,
    ref_unit_subject7 smallint,
    ref_unit_subject8 smallint,
    enabled boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_classroom_id integer NOT NULL,
    fk_term_id integer NOT NULL,
    fk_supervisor_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_classroom_termothersubject OWNER TO postgres;

--
-- TOC entry 334 (class 1259 OID 17456)
-- Name: larcauth_classroom_termsubject; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_classroom_termsubject (
    id integer NOT NULL,
    label character varying(72) NOT NULL,
    description text NOT NULL,
    enabled boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_classroom_id integer NOT NULL,
    fk_levelsubject_id integer NOT NULL,
    fk_term_id integer NOT NULL,
    fk_teacher_id integer NOT NULL,
    couleur character varying(10) NOT NULL,
    niv_sup boolean DEFAULT false,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_classroom_termsubject OWNER TO postgres;

--
-- TOC entry 335 (class 1259 OID 17462)
-- Name: larcauth_concept; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_concept (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    label character varying(36) NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_concept OWNER TO postgres;

--
-- TOC entry 336 (class 1259 OID 17465)
-- Name: larcauth_criteria_of_levelsubject; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_criteria_of_levelsubject (
    id integer NOT NULL,
    criteria_letter character varying(1) NOT NULL,
    criteria_label character varying(72) NOT NULL,
    criteria_description text NOT NULL,
    enabled boolean NOT NULL,
    aspects1nr smallint NOT NULL,
    aspect_11 character varying(222),
    aspect_12 character varying(222),
    aspect_13 character varying(222),
    aspect_14 character varying(222),
    aspect_15 character varying(222),
    aspect_16 character varying(222),
    aspect_17 character varying(222),
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_levelsubject_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_criteria_of_levelsubject OWNER TO postgres;

--
-- TOC entry 337 (class 1259 OID 17470)
-- Name: larcauth_criteria_of_subjectsgroup; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_criteria_of_subjectsgroup (
    id integer NOT NULL,
    criteria_letter character varying(1) NOT NULL,
    criteria_label character varying(72) NOT NULL,
    criteria_description text NOT NULL,
    enabled boolean NOT NULL,
    aspects1nr smallint NOT NULL,
    aspect_11 character varying(222),
    aspect_12 character varying(222),
    aspect_13 character varying(222),
    aspect_14 character varying(222),
    aspect_15 character varying(222),
    aspect_16 character varying(222),
    aspect_17 character varying(222),
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_subjectgroup_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_criteria_of_subjectsgroup OWNER TO postgres;

--
-- TOC entry 338 (class 1259 OID 17475)
-- Name: larcauth_district; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_district (
    id integer NOT NULL,
    label character varying(72) NOT NULL,
    sigle character varying(4) NOT NULL,
    arrondissement character varying(3),
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_district OWNER TO postgres;

--
-- TOC entry 339 (class 1259 OID 17478)
-- Name: larcauth_edt_classe; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_edt_classe (
    id character varying(12) NOT NULL,
    ressource_dow character varying(5),
    title character varying(255),
    text character varying(255),
    starttime time without time zone,
    endtime time without time zone,
    recurrency character varying(255),
    color smallint,
    fk_term smallint,
    fk_classroom integer,
    fk_timeperiod character varying(7),
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_edt_classe OWNER TO postgres;

--
-- TOC entry 340 (class 1259 OID 17483)
-- Name: larcauth_evaluation; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_evaluation (
    id bigint NOT NULL,
    label character varying(3) NOT NULL,
    nature character varying(72),
    "baremeNoteDP" smallint NOT NULL,
    type_evaluation character varying(1) NOT NULL,
    index_eval smallint NOT NULL,
    crit_a boolean,
    aspect_a1 boolean,
    aspect_a2 boolean,
    aspect_a3 boolean,
    aspect_a4 boolean,
    aspect_a5 boolean,
    aspect_a6 boolean,
    aspect_a7 boolean,
    crit_b boolean,
    aspect_b1 boolean,
    aspect_b2 boolean,
    aspect_b3 boolean,
    aspect_b4 boolean,
    aspect_b5 boolean,
    aspect_b6 boolean,
    aspect_b7 boolean,
    crit_c boolean,
    aspect_c1 boolean,
    aspect_c2 boolean,
    aspect_c3 boolean,
    aspect_c4 boolean,
    aspect_c5 boolean,
    aspect_c6 boolean,
    aspect_c7 boolean,
    crit_d boolean,
    aspect_d1 boolean,
    aspect_d2 boolean,
    aspect_d3 boolean,
    aspect_d4 boolean,
    aspect_d5 boolean,
    aspect_d6 boolean,
    aspect_d7 boolean,
    crit_e boolean,
    aspect_e1 boolean,
    aspect_e2 boolean,
    aspect_e3 boolean,
    aspect_e4 boolean,
    aspect_e5 boolean,
    aspect_e6 boolean,
    aspect_e7 boolean,
    crit_f boolean,
    aspect_f1 boolean,
    aspect_f2 boolean,
    aspect_f3 boolean,
    aspect_f4 boolean,
    aspect_f5 boolean,
    aspect_f6 boolean,
    aspect_f7 boolean,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_classroom_termsubject_id integer NOT NULL,
    "baremeNoteCritere" smallint NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_evaluation OWNER TO postgres;

--
-- TOC entry 341 (class 1259 OID 17486)
-- Name: larcauth_gender; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_gender (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    label character varying(12) NOT NULL,
    sigle character varying(4) NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_gender OWNER TO postgres;

--
-- TOC entry 342 (class 1259 OID 17489)
-- Name: larcauth_globalcontext; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_globalcontext (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    label character varying(55) NOT NULL,
    description text NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_globalcontext OWNER TO postgres;

--
-- TOC entry 343 (class 1259 OID 17494)
-- Name: larcauth_language; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_language (
    id integer NOT NULL,
    sigle character varying(2) NOT NULL,
    label character varying(15) NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_language OWNER TO postgres;

--
-- TOC entry 344 (class 1259 OID 17497)
-- Name: larcauth_learner_has_subjectgroup; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learner_has_subjectgroup (
    id integer NOT NULL,
    note_on_7 smallint,
    sum_on_7 smallint,
    average_on_7 smallint,
    description character varying(1500) NOT NULL,
    enabled boolean NOT NULL,
    validated boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_subjectgroup_id integer NOT NULL,
    fk_term_id integer NOT NULL,
    fk_student_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learner_has_subjectgroup OWNER TO postgres;

--
-- TOC entry 345 (class 1259 OID 17502)
-- Name: larcauth_learner_has_term; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learner_has_term (
    id integer NOT NULL,
    term_mark_on_56 smallint,
    term_mark_on_45 smallint,
    term_eetdc_bonus smallint,
    observation_global text,
    observation_profil text,
    term_average_global_on_20 double precision,
    enabled boolean NOT NULL,
    validated boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_term_id integer NOT NULL,
    fk_student_id integer NOT NULL,
    term_subject_choice_ok boolean NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learner_has_term OWNER TO postgres;

--
-- TOC entry 346 (class 1259 OID 17507)
-- Name: larcauth_learner_has_termothersubject; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learner_has_termothersubject (
    id integer NOT NULL,
    titre character varying(144) NOT NULL,
    bareme smallint,
    mark_on_bareme double precision,
    mark_on_20 double precision,
    mark_on_letter character varying(1),
    observation_global text,
    observation_target character varying(144) NOT NULL,
    os_note_a smallint,
    os_note_b smallint,
    os_note_c smallint,
    os_note_d smallint,
    os_note_e smallint,
    os_note_f smallint,
    os_observation character varying(1500),
    enabled boolean NOT NULL,
    validated boolean NOT NULL,
    ref_teacher_used boolean NOT NULL,
    ref_teacher smallint,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_termothersubject_id integer NOT NULL,
    fk_student_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learner_has_termothersubject OWNER TO postgres;

--
-- TOC entry 347 (class 1259 OID 17512)
-- Name: larcauth_learner_has_termsubject; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learner_has_termsubject (
    id integer NOT NULL,
    enabled boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_classroom_termsubject_id integer NOT NULL,
    fk_student_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learner_has_termsubject OWNER TO postgres;

--
-- TOC entry 348 (class 1259 OID 17515)
-- Name: larcauth_learnerdp_has_termsubjectdp; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learnerdp_has_termsubjectdp (
    learner_has_termsubject_ptr_id integer NOT NULL,
    f01_observation character varying(360),
    f02_observation character varying(360),
    f03_observation character varying(360),
    f04_observation character varying(360),
    f05_observation character varying(360),
    f06_observation character varying(360),
    f07_observation character varying(360),
    f08_observation character varying(360),
    f09_observation character varying(360),
    f10_observation character varying(360),
    f11_observation character varying(360),
    f12_observation character varying(360),
    s01_observation character varying(360),
    s02_observation character varying(360),
    s03_observation character varying(360),
    s04_observation character varying(360),
    s05_observation character varying(360),
    s06_observation character varying(360),
    s07_observation character varying(360),
    s08_observation character varying(360),
    s09_observation character varying(360),
    s10_observation character varying(360),
    s11_observation character varying(360),
    s12_observation character varying(360),
    f01_note double precision,
    f01_note_a smallint,
    f01_note_b smallint,
    f01_note_c smallint,
    f01_note_d smallint,
    f01_note_e smallint,
    f01_note_f smallint,
    f02_note double precision,
    f02_note_a smallint,
    f02_note_b smallint,
    f02_note_c smallint,
    f02_note_d smallint,
    f02_note_e smallint,
    f02_note_f smallint,
    f03_note double precision,
    f03_note_a smallint,
    f03_note_b smallint,
    f03_note_c smallint,
    f03_note_d smallint,
    f03_note_e smallint,
    f03_note_f smallint,
    f04_note double precision,
    f04_note_a smallint,
    f04_note_b smallint,
    f04_note_c smallint,
    f04_note_d smallint,
    f04_note_e smallint,
    f04_note_f smallint,
    f05_note double precision,
    f05_note_a smallint,
    f05_note_b smallint,
    f05_note_c smallint,
    f05_note_d smallint,
    f05_note_e smallint,
    f05_note_f smallint,
    f06_note double precision,
    f06_note_a smallint,
    f06_note_b smallint,
    f06_note_c smallint,
    f06_note_d smallint,
    f06_note_e smallint,
    f06_note_f smallint,
    f07_note double precision,
    f07_note_a smallint,
    f07_note_b smallint,
    f07_note_c smallint,
    f07_note_d smallint,
    f07_note_e smallint,
    f07_note_f smallint,
    f08_note double precision,
    f08_note_a smallint,
    f08_note_b smallint,
    f08_note_c smallint,
    f08_note_d smallint,
    f08_note_e smallint,
    f08_note_f smallint,
    f09_note double precision,
    f09_note_a smallint,
    f09_note_b smallint,
    f09_note_c smallint,
    f09_note_d smallint,
    f09_note_e smallint,
    f09_note_f smallint,
    f10_note double precision,
    f10_note_a smallint,
    f10_note_b smallint,
    f10_note_c smallint,
    f10_note_d smallint,
    f10_note_e smallint,
    f10_note_f smallint,
    f11_note double precision,
    f11_note_a smallint,
    f11_note_b smallint,
    f11_note_c smallint,
    f11_note_d smallint,
    f11_note_e smallint,
    f11_note_f smallint,
    f12_note double precision,
    f12_note_a smallint,
    f12_note_b smallint,
    f12_note_c smallint,
    f12_note_d smallint,
    f12_note_e smallint,
    f12_note_f smallint,
    s01_note double precision,
    s01_note_a smallint,
    s01_note_b smallint,
    s01_note_c smallint,
    s01_note_d smallint,
    s01_note_e smallint,
    s01_note_f smallint,
    s02_note double precision,
    s02_note_a smallint,
    s02_note_b smallint,
    s02_note_c smallint,
    s02_note_d smallint,
    s02_note_e smallint,
    s02_note_f smallint,
    s03_note double precision,
    s03_note_a smallint,
    s03_note_b smallint,
    s03_note_c smallint,
    s03_note_d smallint,
    s03_note_e smallint,
    s03_note_f smallint,
    s04_note double precision,
    s04_note_a smallint,
    s04_note_b smallint,
    s04_note_c smallint,
    s04_note_d smallint,
    s04_note_e smallint,
    s04_note_f smallint,
    s05_note double precision,
    s05_note_a smallint,
    s05_note_b smallint,
    s05_note_c smallint,
    s05_note_d smallint,
    s05_note_e smallint,
    s05_note_f smallint,
    s06_note double precision,
    s06_note_a smallint,
    s06_note_b smallint,
    s06_note_c smallint,
    s06_note_d smallint,
    s06_note_e smallint,
    s06_note_f smallint,
    s07_note double precision,
    s07_note_a smallint,
    s07_note_b smallint,
    s07_note_c smallint,
    s07_note_d smallint,
    s07_note_e smallint,
    s07_note_f smallint,
    s08_note double precision,
    s08_note_a smallint,
    s08_note_b smallint,
    s08_note_c smallint,
    s08_note_d smallint,
    s08_note_e smallint,
    s08_note_f smallint,
    s09_note double precision,
    s09_note_a smallint,
    s09_note_b smallint,
    s09_note_c smallint,
    s09_note_d smallint,
    s09_note_e smallint,
    s09_note_f smallint,
    s10_note double precision,
    s10_note_a smallint,
    s10_note_b smallint,
    s10_note_c smallint,
    s10_note_d smallint,
    s10_note_e smallint,
    s10_note_f smallint,
    s11_note double precision,
    s11_note_a smallint,
    s11_note_b smallint,
    s11_note_c smallint,
    s11_note_d smallint,
    s11_note_e smallint,
    s11_note_f smallint,
    s12_note double precision,
    s12_note_a smallint,
    s12_note_b smallint,
    s12_note_c smallint,
    s12_note_d smallint,
    s12_note_e smallint,
    s12_note_f smallint,
    cp_note double precision,
    cp_note_a smallint,
    cp_note_b smallint,
    cp_note_c smallint,
    cp_note_d smallint,
    cp_note_e smallint,
    cp_note_f smallint,
    jgt_a smallint,
    jgt_b smallint,
    jgt_c smallint,
    jgt_d smallint,
    jgt_e smallint,
    jgt_f smallint,
    ei_note double precision,
    ei_observation character varying(2000),
    ei_objectif character varying(250),
    cpei double precision,
    cc_on_20 double precision,
    moy_on_20 double precision,
    moy_on_7 double precision,
    bacblanc_v double precision,
    bacblanc smallint,
    term_observation text,
    cp_observation character varying(360),
    f13_obsersation character varying(360),
    f14_obsersation character varying(360),
    f15_obsersation character varying(360),
    jgt_obsersation character varying(1200),
    s13_note double precision,
    s13_note_a smallint,
    s13_note_b smallint,
    s13_note_c smallint,
    s13_note_d smallint,
    s13_note_e smallint,
    s13_note_f smallint,
    s13_observation character varying(720),
    s14_note double precision,
    s14_note_a smallint,
    s14_note_b smallint,
    s14_note_c smallint,
    s14_note_d smallint,
    s14_note_e smallint,
    s14_note_f smallint,
    s14_observation character varying(360),
    s15_note double precision,
    s15_note_a smallint,
    s15_note_b smallint,
    s15_note_c smallint,
    s15_note_d smallint,
    s15_note_e smallint,
    s15_note_f smallint,
    s15_observation character varying(1200),
    bacblanc2 smallint,
    bacblanc_v2 double precision,
    f13_note double precision,
    f13_note_a smallint[],
    f13_note_b smallint[],
    f13_note_c smallint[],
    f13_note_d smallint[],
    f13_note_e smallint[],
    f13_note_f smallint[],
    f14_note double precision[],
    f14_note_a smallint[],
    f14_note_b smallint[],
    f14_note_c smallint[],
    f14_note_d smallint[],
    f14_note_e smallint[],
    f14_note_f smallint[],
    f15_note double precision[],
    f15_note_a smallint[],
    f15_note_b smallint[],
    f15_note_c smallint[],
    f15_note_d smallint[],
    f15_note_e smallint[],
    f15_note_f smallint[],
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learnerdp_has_termsubjectdp OWNER TO postgres;

--
-- TOC entry 349 (class 1259 OID 17520)
-- Name: larcauth_learnermat_has_devpers_unit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learnermat_has_devpers_unit (
    id integer NOT NULL,
    fk_student_id integer NOT NULL,
    fk_devpers_unit_id integer NOT NULL,
    enabled boolean DEFAULT false,
    ref_unit_nr integer NOT NULL,
    status public.status_acquisition_type,
    a boolean,
    pa boolean,
    na boolean,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learnermat_has_devpers_unit OWNER TO postgres;

--
-- TOC entry 350 (class 1259 OID 17524)
-- Name: larcauth_learnermat_has_subjectevals_unit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learnermat_has_subjectevals_unit (
    id integer NOT NULL,
    fk_student_id integer NOT NULL,
    fk_subjectevals_unit_id integer NOT NULL,
    disabled boolean DEFAULT false,
    enabled boolean DEFAULT false,
    ref_unit_nr integer NOT NULL,
    status public.status_acquisition_type,
    a boolean,
    pa boolean,
    na boolean,
    value smallint DEFAULT 0,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learnermat_has_subjectevals_unit OWNER TO postgres;

--
-- TOC entry 351 (class 1259 OID 17530)
-- Name: larcauth_learnermat_has_unit_period; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learnermat_has_unit_period (
    id integer NOT NULL,
    observation_global text,
    observation_profil text,
    unit_average_global_on_20 double precision,
    enabled boolean NOT NULL,
    validated boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_unit_period_id integer NOT NULL,
    fk_student_id integer NOT NULL,
    b0_devpers boolean DEFAULT true NOT NULL,
    b1_langue boolean DEFAULT true NOT NULL,
    b2_math boolean DEFAULT true,
    b3_explore boolean DEFAULT true NOT NULL,
    b4_sport boolean DEFAULT true NOT NULL,
    b5_arts boolean DEFAULT true NOT NULL,
    note_lang_cat1 character varying(2) DEFAULT '-'::character varying,
    note_lang_cat2 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note_lang_cat3 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note_lang_cat4 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note2_math_cat1 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note2_math_cat2 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note2_math_cat3 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note2_math_cat4 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note3_expl_cat1 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note3_expl_cat2 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note3_expl_cat3 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note3_expl_cat4 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note4_arts_cat1 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note4_arts_cat2 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note4_arts_cat3 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note4_arts_cat4 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note5_phys_cat1 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note5_phys_cat2 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note5_phys_cat3 character varying(2) DEFAULT '-'::character varying NOT NULL,
    note5_phys_cat4 character varying(2) DEFAULT '-'::character varying NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learnermat_has_unit_period OWNER TO postgres;

--
-- TOC entry 352 (class 1259 OID 17561)
-- Name: larcauth_learnerpei_has_termsubjectpei; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learnerpei_has_termsubjectpei (
    learner_has_termsubject_ptr_id integer NOT NULL,
    f01_observation character varying(360),
    f02_observation character varying(360),
    f03_observation character varying(360),
    f04_observation character varying(360),
    f05_observation character varying(360),
    f06_observation character varying(360),
    f07_observation character varying(360),
    f08_observation character varying(360),
    f09_observation character varying(360),
    f10_observation character varying(360),
    f11_observation character varying(360),
    f12_observation character varying(360),
    s01_observation character varying(360),
    s02_observation character varying(360),
    s03_observation character varying(360),
    s04_observation character varying(360),
    s05_observation character varying(360),
    s06_observation character varying(360),
    s07_observation character varying(360),
    s08_observation character varying(360),
    s09_observation character varying(360),
    s10_observation character varying(360),
    s11_observation character varying(360),
    s12_observation character varying(360),
    f01_note_a smallint,
    f01_note_b smallint,
    f01_note_c smallint,
    f01_note_d smallint,
    f01_note_e smallint,
    f01_note_f smallint,
    f02_note_a smallint,
    f02_note_b smallint,
    f02_note_c smallint,
    f02_note_d smallint,
    f02_note_e smallint,
    f02_note_f smallint,
    f03_note_a smallint,
    f03_note_b smallint,
    f03_note_c smallint,
    f03_note_d smallint,
    f03_note_e smallint,
    f03_note_f smallint,
    f04_note_a smallint,
    f04_note_b smallint,
    f04_note_c smallint,
    f04_note_d smallint,
    f04_note_e smallint,
    f04_note_f smallint,
    f05_note_a smallint,
    f05_note_b smallint,
    f05_note_c smallint,
    f05_note_d smallint,
    f05_note_e smallint,
    f05_note_f smallint,
    f06_note_a smallint,
    f06_note_b smallint,
    f06_note_c smallint,
    f06_note_d smallint,
    f06_note_e smallint,
    f06_note_f smallint,
    f07_note_a smallint,
    f07_note_b smallint,
    f07_note_c smallint,
    f07_note_d smallint,
    f07_note_e smallint,
    f07_note_f smallint,
    f08_note_a smallint,
    f08_note_b smallint,
    f08_note_c smallint,
    f08_note_d smallint,
    f08_note_e smallint,
    f08_note_f smallint,
    f09_note_a smallint,
    f09_note_b smallint,
    f09_note_c smallint,
    f09_note_d smallint,
    f09_note_e smallint,
    f09_note_f smallint,
    f10_note_a smallint,
    f10_note_b smallint,
    f10_note_c smallint,
    f10_note_d smallint,
    f10_note_e smallint,
    f10_note_f smallint,
    f11_note_a smallint,
    f11_note_b smallint,
    f11_note_c smallint,
    f11_note_d smallint,
    f11_note_e smallint,
    f11_note_f smallint,
    f12_note_a smallint,
    f12_note_b smallint,
    f12_note_c smallint,
    f12_note_d smallint,
    f12_note_e smallint,
    f12_note_f smallint,
    s01_note_a smallint,
    s01_note_b smallint,
    s01_note_c smallint,
    s01_note_d smallint,
    s01_note_e smallint,
    s01_note_f smallint,
    s02_note_a smallint,
    s02_note_b smallint,
    s02_note_c smallint,
    s02_note_d smallint,
    s02_note_e smallint,
    s02_note_f smallint,
    s03_note_a smallint,
    s03_note_b smallint,
    s03_note_c smallint,
    s03_note_d smallint,
    s03_note_e smallint,
    s03_note_f smallint,
    s04_note_a smallint,
    s04_note_b smallint,
    s04_note_c smallint,
    s04_note_d smallint,
    s04_note_e smallint,
    s04_note_f smallint,
    s05_note_a smallint,
    s05_note_b smallint,
    s05_note_c smallint,
    s05_note_d smallint,
    s05_note_e smallint,
    s05_note_f smallint,
    s06_note_a smallint,
    s06_note_b smallint,
    s06_note_c smallint,
    s06_note_d smallint,
    s06_note_e smallint,
    s06_note_f smallint,
    s07_note_a smallint,
    s07_note_b smallint,
    s07_note_c smallint,
    s07_note_d smallint,
    s07_note_e smallint,
    s07_note_f smallint,
    s08_note_a smallint,
    s08_note_b smallint,
    s08_note_c smallint,
    s08_note_d smallint,
    s08_note_e smallint,
    s08_note_f smallint,
    s09_note_a smallint,
    s09_note_b smallint,
    s09_note_c smallint,
    s09_note_d smallint,
    s09_note_e smallint,
    "S09_note_f" smallint,
    s10_note_a smallint,
    s10_note_b smallint,
    s10_note_c smallint,
    s10_note_d smallint,
    s10_note_e smallint,
    s10_note_f smallint,
    s11_note_a smallint,
    s11_note_b smallint,
    s11_note_c smallint,
    s11_note_d smallint,
    s11_note_e smallint,
    s11_note_f smallint,
    s12_note_a smallint,
    s12_note_b smallint,
    s12_note_c smallint,
    s12_note_d smallint,
    s12_note_e smallint,
    s12_note_f smallint,
    s12_note_g smallint,
    cp_note_a smallint,
    cp_note_b smallint,
    cp_note_c smallint,
    cp_note_d smallint,
    cp_note_e smallint,
    cp_note_f smallint,
    cp_observation character varying(72),
    jgt_a smallint,
    jgt_b smallint,
    jgt_c smallint,
    jgt_d smallint,
    jgt_e smallint,
    jgt_f smallint,
    note_on_7 smallint,
    term_observation text,
    f13_obsersation character varying(360),
    f14_obsersation character varying(360),
    f15_obsersation character varying(360),
    s13_note_a smallint,
    s13_note_b smallint,
    s13_note_c smallint,
    s13_note_d smallint,
    s13_note_e smallint,
    s13_note_f smallint,
    s13_observation character varying(360),
    s14_note_a smallint,
    s14_note_b smallint,
    s14_note_c smallint,
    s14_note_d smallint,
    s14_note_e smallint,
    s14_note_f smallint,
    s14_observation character varying(360),
    s15_note_a smallint,
    s15_note_b smallint,
    s15_note_c smallint,
    s15_note_d smallint,
    s15_note_e smallint,
    s15_note_f smallint,
    s15_observation character varying(3000),
    f13_note_a smallint,
    f13_note_b smallint,
    f13_note_c smallint,
    f13_note_d smallint,
    f13_note_e smallint,
    f13_note_f smallint,
    f14_note_a smallint,
    f14_note_b smallint,
    f14_note_c smallint,
    f14_note_d smallint,
    f14_note_e smallint,
    f14_note_f smallint,
    f15_note_a smallint,
    f15_note_b smallint,
    f15_note_c smallint,
    f15_note_d smallint,
    f15_note_e smallint,
    f15_note_f smallint,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learnerpei_has_termsubjectpei OWNER TO postgres;

--
-- TOC entry 353 (class 1259 OID 17566)
-- Name: larcauth_learnerpp_has_termsubjectpp; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learnerpp_has_termsubjectpp (
    learner_has_termsubject_ptr_id integer NOT NULL,
    f01_observation character varying(360),
    f02_observation character varying(360),
    f03_observation character varying(360),
    f04_observation character varying(360),
    f05_observation character varying(360),
    f06_observation character varying(360),
    s01_observation character varying(360),
    s02_observation character varying(360),
    s03_observation character varying(360),
    s04_observation character varying(360),
    s05_observation character varying(360),
    s06_observation character varying(360),
    f01_note double precision,
    f01_note_a smallint,
    f01_note_b smallint,
    f01_note_c smallint,
    f01_note_d smallint,
    f02_note double precision,
    f02_note_a smallint,
    f02_note_b smallint,
    f02_note_c smallint,
    f02_note_d smallint,
    f03_note double precision,
    f03_note_a smallint,
    f03_note_b smallint,
    f03_note_c smallint,
    f03_note_d smallint,
    f04_note double precision,
    f04_note_a smallint,
    f04_note_b smallint,
    f04_note_c smallint,
    f04_note_d smallint,
    s01_note double precision,
    s01_note_a smallint,
    s01_note_b smallint,
    s01_note_c smallint,
    s01_note_d smallint,
    s02_note double precision,
    s02_note_a smallint,
    s02_note_b smallint,
    s02_note_c smallint,
    s02_note_d smallint,
    s03_note double precision,
    s03_note_a smallint,
    s03_note_b smallint,
    s03_note_c smallint,
    s03_note_d smallint,
    s04_note double precision,
    s04_note_a smallint,
    s04_note_b smallint,
    s04_note_c smallint,
    s04_note_d smallint,
    s05_note double precision,
    s05_note_a smallint,
    s05_note_b smallint,
    s05_note_c smallint,
    s05_note_d smallint,
    s06_note double precision,
    s06_note_a smallint,
    s06_note_b smallint,
    s06_note_c smallint,
    s06_note_d smallint,
    cp_note double precision,
    jgt_a smallint,
    jgt_b smallint,
    jgt_c smallint,
    jgt_d smallint,
    note_unit1 smallint,
    note_unit2 smallint,
    note_unit3 smallint,
    note_unit4 smallint,
    note_unit5 smallint,
    note_unit6 smallint,
    note_for_term smallint,
    term_observation text,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learnerpp_has_termsubjectpp OWNER TO postgres;

--
-- TOC entry 354 (class 1259 OID 17571)
-- Name: larcauth_learnerprim_has_unit_period; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_learnerprim_has_unit_period (
    id integer NOT NULL,
    unit_mark_on_max smallint,
    unit_eetdc_bonus smallint,
    observation_global text,
    observation_profil text,
    unit_average_global_on_20 double precision,
    enabled boolean NOT NULL,
    validated boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_unit_period_id integer NOT NULL,
    fk_student_id integer NOT NULL,
    b_la boolean DEFAULT true NOT NULL,
    b_lb boolean DEFAULT true,
    b_ma boolean DEFAULT true NOT NULL,
    b_sc boolean DEFAULT true NOT NULL,
    b_hu boolean DEFAULT true NOT NULL,
    b_ar boolean DEFAULT true NOT NULL,
    b_sp boolean DEFAULT true NOT NULL,
    b_tr boolean DEFAULT true NOT NULL,
    f_la_a smallint,
    f_la_b smallint,
    f_la_c smallint,
    f_la_d smallint,
    f_la smallint,
    f_lb_a smallint,
    f_lb_b smallint,
    f_lb_c smallint,
    f_lb_d smallint,
    f_lb smallint,
    f_ma_a smallint,
    f_ma_b smallint,
    f_ma_c smallint,
    f_ma_d smallint,
    f_ma smallint,
    f_sc smallint,
    f_hu smallint,
    f_sp smallint,
    f_ar smallint,
    f_tr smallint,
    s_la_a smallint,
    s_la_b smallint,
    s_la_c smallint,
    s_la_d smallint,
    s_la smallint,
    s_lb_a smallint,
    s_lb_b smallint,
    s_lb_c smallint,
    s_lb_d smallint,
    s_lb smallint,
    s_ma_a smallint,
    s_ma_b smallint,
    s_ma_c smallint,
    s_ma_d smallint,
    s_ma smallint,
    s_sc smallint,
    s_hu smallint,
    s_sp smallint,
    s_ar smallint,
    s_tr smallint,
    nb_mat smallint DEFAULT 0 NOT NULL,
    note_on_max smallint DEFAULT 0 NOT NULL,
    unit_comment text,
    unit_profil_comment text,
    c_la character varying(3000),
    c_lb character varying(3000),
    c_ma character varying(3000),
    c_sc character varying(3000),
    c_hu character varying(3000),
    c_sp character varying(3000),
    c_ar character varying(3000),
    c_tr character varying(3000),
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_learnerprim_has_unit_period OWNER TO postgres;

--
-- TOC entry 355 (class 1259 OID 17586)
-- Name: larcauth_level; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_level (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    label character varying(33) NOT NULL,
    description text NOT NULL,
    level_in_pgm smallint NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    fk_program_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_level OWNER TO postgres;

--
-- TOC entry 356 (class 1259 OID 17591)
-- Name: larcauth_levelsubject; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_levelsubject (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    label character varying(55) NOT NULL,
    description text NOT NULL,
    enabled boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    fk_level_id integer NOT NULL,
    fk_subjectgroup_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_levelsubject OWNER TO postgres;

--
-- TOC entry 357 (class 1259 OID 17596)
-- Name: larcauth_lieu; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_lieu (
    "IDLieu" smallint NOT NULL,
    "s_IDLieu" smallint NOT NULL,
    "Lieu" character varying(72) NOT NULL,
    fk_language smallint NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_lieu OWNER TO postgres;

--
-- TOC entry 358 (class 1259 OID 17599)
-- Name: larcauth_mat_devpers_gene; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_mat_devpers_gene (
    s_id integer NOT NULL,
    leveldevpers smallint DEFAULT 0,
    skillcategory character varying(144),
    skill character varying(144),
    skillactivity character varying(144),
    enabled boolean DEFAULT false,
    fk_language_id integer,
    pk_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_mat_devpers_gene OWNER TO postgres;

--
-- TOC entry 359 (class 1259 OID 17604)
-- Name: larcauth_mat_devpers_unit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_mat_devpers_unit (
    pk_id integer NOT NULL,
    leveldevpers smallint DEFAULT 0,
    skillcategory character varying(72),
    skill character varying(72),
    skillactivity character varying(72),
    enabled boolean DEFAULT false,
    fk_unit_period integer,
    s_id integer,
    "ref_Language" integer,
    ref_unit_nr smallint DEFAULT 0,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_mat_devpers_unit OWNER TO postgres;

--
-- TOC entry 360 (class 1259 OID 17610)
-- Name: larcauth_mat_subjectevals_unit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_mat_subjectevals_unit (
    id integer NOT NULL,
    label character varying(72),
    skillcategory character varying(72),
    skill_category integer,
    skill_evaluated integer,
    enabled boolean DEFAULT false,
    validated boolean DEFAULT false,
    date_eval date,
    date_valid date,
    ref_unit_nr smallint DEFAULT 0,
    fk_classroom_id integer,
    fk_unit_period integer,
    ref_test_nr integer,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_mat_subjectevals_unit OWNER TO postgres;

--
-- TOC entry 361 (class 1259 OID 17616)
-- Name: larcauth_mat_subjectskills; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_mat_subjectskills (
    s_id integer NOT NULL,
    levelsubjeskill smallint DEFAULT 0,
    skillsubject character varying(144),
    skillcat character varying(144),
    subjectskill character varying(144),
    enabled boolean DEFAULT false,
    fk_language_id integer,
    pk_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_mat_subjectskills OWNER TO postgres;

--
-- TOC entry 362 (class 1259 OID 17621)
-- Name: larcauth_mat_subjectskills_unit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_mat_subjectskills_unit (
    pk_id integer NOT NULL,
    levelsubjectskill smallint DEFAULT 0,
    skillsubject character varying(72),
    skillcat character varying(72),
    subjectskill character varying(72),
    enabled boolean DEFAULT false,
    fk_unit_period integer,
    s_id integer,
    "ref_Language" integer,
    ref_unit_nr smallint DEFAULT 0,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_mat_subjectskills_unit OWNER TO postgres;

--
-- TOC entry 363 (class 1259 OID 17627)
-- Name: larcauth_mat_unit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_mat_unit (
    id integer NOT NULL,
    label character varying(10) NOT NULL,
    title character varying(144) NOT NULL,
    soi character varying(250) NOT NULL,
    loi character varying(250) NOT NULL,
    date_start date,
    date_end date,
    duration character varying(55),
    content character varying(255),
    finaltask character varying(255),
    details text NOT NULL,
    fk_relconcept1 smallint DEFAULT 0,
    fk_relconcept2 smallint DEFAULT 0,
    fk_relconcept3 smallint DEFAULT 0,
    fk_relconcept4 smallint DEFAULT 0,
    id_order_in_year smallint NOT NULL,
    fk_classroom_id integer NOT NULL,
    fk_globalcontext_id integer DEFAULT 0,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_mat_unit OWNER TO postgres;

--
-- TOC entry 364 (class 1259 OID 17637)
-- Name: larcauth_natureparentutor; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_natureparentutor (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    label character varying(10) NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_natureparentutor OWNER TO postgres;

--
-- TOC entry 365 (class 1259 OID 17640)
-- Name: larcauth_program; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_program (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    sigle character varying(4) NOT NULL,
    label character varying(55) NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_program OWNER TO postgres;

--
-- TOC entry 366 (class 1259 OID 17643)
-- Name: larcauth_student; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_student (
    aecuser_ptr_id integer NOT NULL,
    aec_id character varying(12) NOT NULL,
    enabled boolean NOT NULL,
    created_s timestamp with time zone NOT NULL,
    updated_s timestamp with time zone NOT NULL,
    s_classroom_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_student OWNER TO postgres;

--
-- TOC entry 367 (class 1259 OID 17646)
-- Name: larcauth_student_has_dayevents; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_student_has_dayevents (
    id bigint NOT NULL,
    nbre_absence smallint NOT NULL,
    nbre_retards smallint NOT NULL,
    nbre_sorties smallint NOT NULL,
    nbre_comportements smallint NOT NULL,
    nbre_profil smallint NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_student_id bigint NOT NULL,
    fk_day_id bigint NOT NULL,
    "Absence" boolean DEFAULT false NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_student_has_dayevents OWNER TO postgres;

--
-- TOC entry 368 (class 1259 OID 17650)
-- Name: larcauth_student_has_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_student_has_events (
    id bigint NOT NULL,
    enabled boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_jour_id bigint NOT NULL,
    fk_student_id bigint NOT NULL,
    fk_typeevent_id smallint DEFAULT 0,
    ref_staff bigint NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_student_has_events OWNER TO postgres;

--
-- TOC entry 369 (class 1259 OID 17654)
-- Name: larcauth_student_has_termevents; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_student_has_termevents (
    id bigint NOT NULL,
    nbre_absence smallint NOT NULL,
    nbre_retards smallint NOT NULL,
    nbre_sorties smallint NOT NULL,
    nbre_comportements smallint NOT NULL,
    nbre_profil smallint NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_student_id bigint NOT NULL,
    fk_term_id smallint NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_student_has_termevents OWNER TO postgres;

--
-- TOC entry 370 (class 1259 OID 17657)
-- Name: larcauth_student_has_weekevents; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_student_has_weekevents (
    id bigint NOT NULL,
    nbre_absence smallint NOT NULL,
    nbre_retards smallint NOT NULL,
    nbre_sorties smallint NOT NULL,
    nbre_comportements smallint NOT NULL,
    nbre_profil smallint NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_student_id bigint NOT NULL,
    fk_term_id smallint NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_student_has_weekevents OWNER TO postgres;

--
-- TOC entry 371 (class 1259 OID 17660)
-- Name: larcauth_subjectgroup; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_subjectgroup (
    id integer NOT NULL,
    s_id smallint NOT NULL,
    label character varying(44) NOT NULL,
    description text NOT NULL,
    nr_group_in_pgm smallint NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    fk_program_id integer NOT NULL,
    fk_coordonator_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_subjectgroup OWNER TO postgres;

--
-- TOC entry 387 (class 1259 OID 18629)
-- Name: larcauth_sync_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_sync_log (
    id bigint NOT NULL,
    table_name text NOT NULL,
    operation text NOT NULL,
    old_data jsonb,
    new_data jsonb,
    changed_by text,
    changed_at timestamp with time zone DEFAULT now(),
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_sync_log OWNER TO postgres;

--
-- TOC entry 386 (class 1259 OID 18628)
-- Name: larcauth_sync_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.larcauth_sync_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.larcauth_sync_log_id_seq OWNER TO postgres;

--
-- TOC entry 4696 (class 0 OID 0)
-- Dependencies: 386
-- Name: larcauth_sync_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.larcauth_sync_log_id_seq OWNED BY public.larcauth_sync_log.id;


--
-- TOC entry 372 (class 1259 OID 17665)
-- Name: larcauth_teachadm; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_teachadm (
    aecuser_ptr_id integer NOT NULL,
    is_teacher boolean NOT NULL,
    is_adm boolean NOT NULL,
    is_coordonator boolean NOT NULL,
    is_secretary boolean NOT NULL,
    enabled boolean NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_teachadm OWNER TO postgres;

--
-- TOC entry 373 (class 1259 OID 17668)
-- Name: larcauth_term; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_term (
    id integer NOT NULL,
    "trim" smallint NOT NULL,
    label character varying(15) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_term OWNER TO postgres;

--
-- TOC entry 374 (class 1259 OID 17671)
-- Name: larcauth_termsubject_has_homework; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_termsubject_has_homework (
    id integer NOT NULL,
    time_1 time without time zone,
    nature_1 character varying(72),
    todo_1 text,
    time_2 time without time zone,
    nature_2 character varying(72),
    todo_2 text,
    time_3 time without time zone,
    nature_3 character varying(72),
    todo_3 text,
    enabled boolean NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_classroom_termsubject_id integer NOT NULL,
    fk_jour_id integer,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_termsubject_has_homework OWNER TO postgres;

--
-- TOC entry 375 (class 1259 OID 17676)
-- Name: larcauth_timeperiod; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_timeperiod (
    id character varying(6) NOT NULL,
    debut time without time zone,
    fin time without time zone,
    weekday smallint,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_timeperiod OWNER TO postgres;

--
-- TOC entry 376 (class 1259 OID 17679)
-- Name: larcauth_type_event; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_type_event (
    idtypeevent smallint NOT NULL,
    type_event character varying(72),
    "Event_Niveau2" character varying(72),
    "Event_Niveau3" character varying(72),
    "Enabled" boolean DEFAULT false,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.larcauth_type_event OWNER TO postgres;

--
-- TOC entry 377 (class 1259 OID 17683)
-- Name: larcauth_unit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_unit (
    id integer NOT NULL,
    label character varying(10) NOT NULL,
    title character varying(144) NOT NULL,
    soi character varying(250) NOT NULL,
    loi character varying(250) NOT NULL,
    date_start date,
    date_end date,
    duration character varying(55),
    content character varying(255),
    finaltask character varying(255),
    details text NOT NULL,
    "crit_A" boolean DEFAULT false NOT NULL,
    "aspect_A1" boolean DEFAULT false NOT NULL,
    "aspect_A2" boolean DEFAULT false NOT NULL,
    "aspect_A3" boolean DEFAULT false NOT NULL,
    "aspect_A4" boolean DEFAULT false NOT NULL,
    "aspect_A5" boolean DEFAULT false NOT NULL,
    "aspect_A6" boolean DEFAULT false NOT NULL,
    "aspect_A7" boolean DEFAULT false NOT NULL,
    "crit_B" boolean DEFAULT false NOT NULL,
    "aspect_B1" boolean DEFAULT false NOT NULL,
    "aspect_B2" boolean DEFAULT false NOT NULL,
    "aspect_B3" boolean DEFAULT false NOT NULL,
    "aspect_B4" boolean DEFAULT false NOT NULL,
    "aspect_B5" boolean DEFAULT false NOT NULL,
    "aspect_B6" boolean DEFAULT false NOT NULL,
    "aspect_B7" boolean DEFAULT false NOT NULL,
    "crit_C" boolean DEFAULT false NOT NULL,
    "aspect_C1" boolean DEFAULT false NOT NULL,
    "aspect_C2" boolean DEFAULT false NOT NULL,
    "aspect_C3" boolean DEFAULT false NOT NULL,
    "aspect_C4" boolean DEFAULT false NOT NULL,
    "aspect_C5" boolean DEFAULT false NOT NULL,
    "aspect_C6" boolean DEFAULT false NOT NULL,
    "aspect_C7" boolean DEFAULT false NOT NULL,
    "crit_D" boolean DEFAULT false NOT NULL,
    "aspect_D1" boolean DEFAULT false NOT NULL,
    "aspect_D2" boolean DEFAULT false NOT NULL,
    "aspect_D3" boolean DEFAULT false NOT NULL,
    "aspect_D4" boolean DEFAULT false NOT NULL,
    "aspect_D5" boolean DEFAULT false NOT NULL,
    "aspect_D6" boolean DEFAULT false NOT NULL,
    "aspect_D7" boolean DEFAULT false NOT NULL,
    "crit_E" boolean DEFAULT false NOT NULL,
    "aspect_E1" boolean DEFAULT false NOT NULL,
    "aspect_E2" boolean DEFAULT false NOT NULL,
    "aspect_E3" boolean DEFAULT false NOT NULL,
    "aspect_E4" boolean DEFAULT false NOT NULL,
    "aspect_E5" boolean DEFAULT false NOT NULL,
    "aspect_E6" boolean DEFAULT false NOT NULL,
    "aspect_E7" boolean DEFAULT false NOT NULL,
    "crit_F" boolean DEFAULT false NOT NULL,
    aspect_f1 boolean DEFAULT false NOT NULL,
    "aspect_F2" boolean DEFAULT false NOT NULL,
    "aspect_F3" boolean DEFAULT false NOT NULL,
    "aspect_F4" boolean DEFAULT false NOT NULL,
    "aspect_F5" boolean DEFAULT false NOT NULL,
    "aspect_F6" boolean DEFAULT false NOT NULL,
    "aspect_F7" boolean DEFAULT false NOT NULL,
    fk_relconcept1 smallint DEFAULT 0,
    fk_relconcept2 smallint DEFAULT 0,
    fk_relconcept3 smallint DEFAULT 0,
    fk_relconcept4 smallint DEFAULT 0,
    id_order_in_yearsubject smallint NOT NULL,
    fk_classroom_termsubject_id integer NOT NULL,
    fk_globalcontext_id integer DEFAULT 0,
    fk_keyconcept_id integer DEFAULT 0,
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_unit OWNER TO postgres;

--
-- TOC entry 378 (class 1259 OID 17742)
-- Name: larcauth_unit_period; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.larcauth_unit_period (
    id integer NOT NULL,
    unit_nr smallint NOT NULL,
    label character varying(15) NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    created timestamp with time zone NOT NULL,
    updated timestamp with time zone NOT NULL,
    fk_language_id integer NOT NULL,
    titre1_lang character varying(72),
    titre1_lang_cat1 character varying(72),
    titre1_lang_cat2 character varying(72),
    titre1_lang_cat3 character varying(72),
    titre1_lang_cat4 character varying(72),
    titre2_math character varying(72),
    titre2_math_cat1 character varying(72),
    titre2_math_cat2 character varying(72),
    titre2_math_cat3 character varying(72),
    titre2_math_cat4 character varying(72),
    titre3_expl character varying(72),
    titre3_expl_cat1 character varying(72),
    titre3_expl_cat2 character varying(72),
    titre3_expl_cat3 character varying(72),
    titre3_expl_cat4 character varying(72),
    titre4_arts character varying(72),
    titre4_arts_cat1 character varying(72),
    titre4_arts_cat2 character varying(72),
    titre4_arts_cat3 character varying(72),
    titre4_arts_cat4 character varying(72),
    titre5_phys character varying(72),
    titre5_phys_cat1 character varying(72),
    titre5_phys_cat2 character varying(72),
    titre5_phys_cat3 character varying(72),
    titre5_phys_cat4 character varying(72),
    sync_version integer DEFAULT 0,
    synced_at timestamp with time zone DEFAULT now(),
    synced_by text,
    last_modified_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    sync_revision bigint DEFAULT 0
);


ALTER TABLE public.larcauth_unit_period OWNER TO postgres;

--
-- TOC entry 390 (class 1259 OID 20984)
-- Name: sync_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sync_log (
    seq bigint NOT NULL,
    sync_level smallint NOT NULL,
    table_name text NOT NULL,
    record_id text NOT NULL,
    new_revision bigint NOT NULL,
    modified_by integer,
    old_data jsonb,
    new_data jsonb,
    sync_source text DEFAULT 'intranet'::text,
    logged_at timestamp with time zone DEFAULT now(),
    CONSTRAINT sync_log_sync_level_check CHECK ((sync_level = ANY (ARRAY[1, 2, 3])))
);


ALTER TABLE public.sync_log OWNER TO postgres;

--
-- TOC entry 4705 (class 0 OID 0)
-- Dependencies: 390
-- Name: TABLE sync_log; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.sync_log IS 'Journal global des modifications — pivot du Double Verrou';


--
-- TOC entry 4706 (class 0 OID 0)
-- Dependencies: 390
-- Name: COLUMN sync_log.seq; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_log.seq IS 'Séquence globale monotone croissante — curseur de synchro';


--
-- TOC entry 4707 (class 0 OID 0)
-- Dependencies: 390
-- Name: COLUMN sync_log.sync_level; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_log.sync_level IS '1=Référentiels IB  2=Configuration école  3=Opérationnel';


--
-- TOC entry 4708 (class 0 OID 0)
-- Dependencies: 390
-- Name: COLUMN sync_log.record_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_log.record_id IS 'Valeur de la PK (text pour couvrir tous les types)';


--
-- TOC entry 4709 (class 0 OID 0)
-- Dependencies: 390
-- Name: COLUMN sync_log.new_revision; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_log.new_revision IS 'Valeur de sync_revision après la modification';


--
-- TOC entry 4710 (class 0 OID 0)
-- Dependencies: 390
-- Name: COLUMN sync_log.modified_by; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_log.modified_by IS 'larcauth_aecuser.id de lauteur (sans FK contrainte)';


--
-- TOC entry 4711 (class 0 OID 0)
-- Dependencies: 390
-- Name: COLUMN sync_log.old_data; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_log.old_data IS 'JSON des champs modifiés avant UPDATE (diff uniquement)';


--
-- TOC entry 4712 (class 0 OID 0)
-- Dependencies: 390
-- Name: COLUMN sync_log.new_data; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_log.new_data IS 'JSON des champs modifiés après UPDATE (diff uniquement)';


--
-- TOC entry 4713 (class 0 OID 0)
-- Dependencies: 390
-- Name: COLUMN sync_log.sync_source; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_log.sync_source IS 'Origine : intranet | device | cloud | daemon (anti-boucle)';


--
-- TOC entry 389 (class 1259 OID 20983)
-- Name: sync_log_seq_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.sync_log_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sync_log_seq_seq OWNER TO postgres;

--
-- TOC entry 4715 (class 0 OID 0)
-- Dependencies: 389
-- Name: sync_log_seq_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.sync_log_seq_seq OWNED BY public.sync_log.seq;


--
-- TOC entry 388 (class 1259 OID 20973)
-- Name: sync_state; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sync_state (
    sync_table_name text NOT NULL,
    sync_last_id bigint DEFAULT 0,
    sync_updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.sync_state OWNER TO postgres;

--
-- TOC entry 391 (class 1259 OID 20998)
-- Name: sync_table_config; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.sync_table_config (
    table_name text NOT NULL,
    sync_level smallint NOT NULL,
    sync_enabled boolean DEFAULT true,
    pk_column text DEFAULT 'id'::text,
    description text,
    CONSTRAINT sync_table_config_sync_level_check CHECK ((sync_level = ANY (ARRAY[1, 2, 3])))
);


ALTER TABLE public.sync_table_config OWNER TO postgres;

--
-- TOC entry 4718 (class 0 OID 0)
-- Dependencies: 391
-- Name: TABLE sync_table_config; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.sync_table_config IS 'Configuration de la synchronisation par table — modifiable sans toucher au code';


--
-- TOC entry 4719 (class 0 OID 0)
-- Dependencies: 391
-- Name: COLUMN sync_table_config.sync_level; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_table_config.sync_level IS '1=N1 Référentiels  2=N2 Configuration  3=N3 Opérationnel';


--
-- TOC entry 4720 (class 0 OID 0)
-- Dependencies: 391
-- Name: COLUMN sync_table_config.sync_enabled; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_table_config.sync_enabled IS 'false = trigger présent mais skip silencieux';


--
-- TOC entry 4721 (class 0 OID 0)
-- Dependencies: 391
-- Name: COLUMN sync_table_config.pk_column; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.sync_table_config.pk_column IS 'Nom de la colonne PK (varie selon les tables)';


--
-- TOC entry 4159 (class 2604 OID 18632)
-- Name: larcauth_sync_log id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.larcauth_sync_log ALTER COLUMN id SET DEFAULT nextval('public.larcauth_sync_log_id_seq'::regclass);


--
-- TOC entry 4164 (class 2604 OID 20987)
-- Name: sync_log seq; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sync_log ALTER COLUMN seq SET DEFAULT nextval('public.sync_log_seq_seq'::regclass);


--
-- TOC entry 4172 (class 2606 OID 18637)
-- Name: larcauth_sync_log larcauth_sync_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.larcauth_sync_log
    ADD CONSTRAINT larcauth_sync_log_pkey PRIMARY KEY (id);


--
-- TOC entry 4179 (class 2606 OID 20994)
-- Name: sync_log sync_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sync_log
    ADD CONSTRAINT sync_log_pkey PRIMARY KEY (seq);


--
-- TOC entry 4174 (class 2606 OID 20981)
-- Name: sync_state sync_state_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sync_state
    ADD CONSTRAINT sync_state_pkey PRIMARY KEY (sync_table_name);


--
-- TOC entry 4181 (class 2606 OID 21007)
-- Name: sync_table_config sync_table_config_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.sync_table_config
    ADD CONSTRAINT sync_table_config_pkey PRIMARY KEY (table_name);


--
-- TOC entry 4175 (class 1259 OID 20995)
-- Name: idx_sync_log_level_seq; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sync_log_level_seq ON public.sync_log USING btree (sync_level, seq);


--
-- TOC entry 4176 (class 1259 OID 20997)
-- Name: idx_sync_log_modified_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sync_log_modified_by ON public.sync_log USING btree (modified_by) WHERE (modified_by IS NOT NULL);


--
-- TOC entry 4177 (class 1259 OID 20996)
-- Name: idx_sync_log_table_seq; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_sync_log_table_seq ON public.sync_log USING btree (table_name, seq);


--
-- TOC entry 4182 (class 2620 OID 20719)
-- Name: larcauth_academicyear track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_academicyear FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4187 (class 2620 OID 20734)
-- Name: larcauth_aecuser track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_aecuser FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4192 (class 2620 OID 20773)
-- Name: larcauth_agenda track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_agenda FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4196 (class 2620 OID 20737)
-- Name: larcauth_campus track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_campus FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4201 (class 2620 OID 20731)
-- Name: larcauth_classroom track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_classroom FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4206 (class 2620 OID 20776)
-- Name: larcauth_classroom_has_timeperiod track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_classroom_has_timeperiod FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4211 (class 2620 OID 20746)
-- Name: larcauth_classroom_termothersubject track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_classroom_termothersubject FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4216 (class 2620 OID 20749)
-- Name: larcauth_classroom_termsubject track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_classroom_termsubject FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4221 (class 2620 OID 20752)
-- Name: larcauth_concept track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_concept FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4225 (class 2620 OID 20782)
-- Name: larcauth_criteria_of_levelsubject track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_criteria_of_levelsubject FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4230 (class 2620 OID 20740)
-- Name: larcauth_criteria_of_subjectsgroup track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_criteria_of_subjectsgroup FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4234 (class 2620 OID 20704)
-- Name: larcauth_district track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_district FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4238 (class 2620 OID 20743)
-- Name: larcauth_edt_classe track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_edt_classe FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4243 (class 2620 OID 20779)
-- Name: larcauth_evaluation track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_evaluation FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4248 (class 2620 OID 20725)
-- Name: larcauth_gender track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_gender FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4252 (class 2620 OID 20713)
-- Name: larcauth_globalcontext track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_globalcontext FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4256 (class 2620 OID 20728)
-- Name: larcauth_language track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_language FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4260 (class 2620 OID 20767)
-- Name: larcauth_learner_has_subjectgroup track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learner_has_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4265 (class 2620 OID 20764)
-- Name: larcauth_learner_has_term track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learner_has_term FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4270 (class 2620 OID 20758)
-- Name: larcauth_learner_has_termothersubject track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learner_has_termothersubject FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4275 (class 2620 OID 20761)
-- Name: larcauth_learner_has_termsubject track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learner_has_termsubject FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4280 (class 2620 OID 20785)
-- Name: larcauth_learnerdp_has_termsubjectdp track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learnerdp_has_termsubjectdp FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4285 (class 2620 OID 20755)
-- Name: larcauth_learnermat_has_devpers_unit track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learnermat_has_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4290 (class 2620 OID 20788)
-- Name: larcauth_learnermat_has_subjectevals_unit track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learnermat_has_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4295 (class 2620 OID 20803)
-- Name: larcauth_learnermat_has_unit_period track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learnermat_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4300 (class 2620 OID 20794)
-- Name: larcauth_learnerpei_has_termsubjectpei track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learnerpei_has_termsubjectpei FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4305 (class 2620 OID 20791)
-- Name: larcauth_learnerpp_has_termsubjectpp track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learnerpp_has_termsubjectpp FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4310 (class 2620 OID 20770)
-- Name: larcauth_learnerprim_has_unit_period track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_learnerprim_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4315 (class 2620 OID 20716)
-- Name: larcauth_level track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_level FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4320 (class 2620 OID 20797)
-- Name: larcauth_levelsubject track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_levelsubject FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4325 (class 2620 OID 20809)
-- Name: larcauth_lieu track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_lieu FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4329 (class 2620 OID 20806)
-- Name: larcauth_mat_devpers_gene track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_mat_devpers_gene FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4333 (class 2620 OID 20800)
-- Name: larcauth_mat_devpers_unit track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_mat_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4338 (class 2620 OID 20824)
-- Name: larcauth_mat_subjectevals_unit track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_mat_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4343 (class 2620 OID 20830)
-- Name: larcauth_mat_subjectskills track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_mat_subjectskills FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4347 (class 2620 OID 20827)
-- Name: larcauth_mat_subjectskills_unit track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_mat_subjectskills_unit FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4352 (class 2620 OID 20833)
-- Name: larcauth_mat_unit track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_mat_unit FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4357 (class 2620 OID 20842)
-- Name: larcauth_natureparentutor track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_natureparentutor FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4361 (class 2620 OID 20722)
-- Name: larcauth_program track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_program FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4365 (class 2620 OID 20839)
-- Name: larcauth_student track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_student FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4370 (class 2620 OID 20821)
-- Name: larcauth_student_has_dayevents track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_student_has_dayevents FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4375 (class 2620 OID 20818)
-- Name: larcauth_student_has_events track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_student_has_events FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4380 (class 2620 OID 20815)
-- Name: larcauth_student_has_termevents track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_student_has_termevents FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4385 (class 2620 OID 20812)
-- Name: larcauth_student_has_weekevents track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_student_has_weekevents FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4390 (class 2620 OID 20845)
-- Name: larcauth_subjectgroup track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4428 (class 2620 OID 18798)
-- Name: larcauth_sync_log track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_sync_log FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4395 (class 2620 OID 20836)
-- Name: larcauth_teachadm track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_teachadm FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4400 (class 2620 OID 20857)
-- Name: larcauth_term track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_term FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4405 (class 2620 OID 20707)
-- Name: larcauth_termsubject_has_homework track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_termsubject_has_homework FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4410 (class 2620 OID 20851)
-- Name: larcauth_timeperiod track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_timeperiod FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4414 (class 2620 OID 20848)
-- Name: larcauth_type_event track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_type_event FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4418 (class 2620 OID 20710)
-- Name: larcauth_unit track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_unit FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4423 (class 2620 OID 20854)
-- Name: larcauth_unit_period track_changes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER track_changes AFTER INSERT OR DELETE OR UPDATE ON public.larcauth_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_sync_log();


--
-- TOC entry 4183 (class 2620 OID 21046)
-- Name: larcauth_academicyear trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_academicyear FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4188 (class 2620 OID 21047)
-- Name: larcauth_aecuser trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_aecuser FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4197 (class 2620 OID 21048)
-- Name: larcauth_campus trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_campus FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4202 (class 2620 OID 21049)
-- Name: larcauth_classroom trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_classroom FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4207 (class 2620 OID 21050)
-- Name: larcauth_classroom_has_timeperiod trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_classroom_has_timeperiod FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4212 (class 2620 OID 21051)
-- Name: larcauth_classroom_termothersubject trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_classroom_termothersubject FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4217 (class 2620 OID 21052)
-- Name: larcauth_classroom_termsubject trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_classroom_termsubject FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4226 (class 2620 OID 21053)
-- Name: larcauth_criteria_of_levelsubject trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_criteria_of_levelsubject FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4239 (class 2620 OID 21054)
-- Name: larcauth_edt_classe trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_edt_classe FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4244 (class 2620 OID 21055)
-- Name: larcauth_evaluation trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_evaluation FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4261 (class 2620 OID 21068)
-- Name: larcauth_learner_has_subjectgroup trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learner_has_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4266 (class 2620 OID 21069)
-- Name: larcauth_learner_has_term trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learner_has_term FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4271 (class 2620 OID 21070)
-- Name: larcauth_learner_has_termothersubject trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learner_has_termothersubject FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4276 (class 2620 OID 21071)
-- Name: larcauth_learner_has_termsubject trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learner_has_termsubject FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4281 (class 2620 OID 21072)
-- Name: larcauth_learnerdp_has_termsubjectdp trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learnerdp_has_termsubjectdp FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4286 (class 2620 OID 21073)
-- Name: larcauth_learnermat_has_devpers_unit trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learnermat_has_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4291 (class 2620 OID 21074)
-- Name: larcauth_learnermat_has_subjectevals_unit trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learnermat_has_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4296 (class 2620 OID 21075)
-- Name: larcauth_learnermat_has_unit_period trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learnermat_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4301 (class 2620 OID 21076)
-- Name: larcauth_learnerpei_has_termsubjectpei trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learnerpei_has_termsubjectpei FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4306 (class 2620 OID 21077)
-- Name: larcauth_learnerpp_has_termsubjectpp trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learnerpp_has_termsubjectpp FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4311 (class 2620 OID 21078)
-- Name: larcauth_learnerprim_has_unit_period trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_learnerprim_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4316 (class 2620 OID 21056)
-- Name: larcauth_level trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_level FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4321 (class 2620 OID 21057)
-- Name: larcauth_levelsubject trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_levelsubject FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4334 (class 2620 OID 21058)
-- Name: larcauth_mat_devpers_unit trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_mat_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4339 (class 2620 OID 21059)
-- Name: larcauth_mat_subjectevals_unit trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_mat_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4348 (class 2620 OID 21060)
-- Name: larcauth_mat_subjectskills_unit trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_mat_subjectskills_unit FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4353 (class 2620 OID 21061)
-- Name: larcauth_mat_unit trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_mat_unit FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4366 (class 2620 OID 21067)
-- Name: larcauth_student trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_student FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4371 (class 2620 OID 21079)
-- Name: larcauth_student_has_dayevents trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_student_has_dayevents FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4376 (class 2620 OID 21080)
-- Name: larcauth_student_has_events trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_student_has_events FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4381 (class 2620 OID 21081)
-- Name: larcauth_student_has_termevents trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_student_has_termevents FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4386 (class 2620 OID 21082)
-- Name: larcauth_student_has_weekevents trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_student_has_weekevents FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4391 (class 2620 OID 21062)
-- Name: larcauth_subjectgroup trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4396 (class 2620 OID 21063)
-- Name: larcauth_teachadm trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_teachadm FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4401 (class 2620 OID 21064)
-- Name: larcauth_term trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_term FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4406 (class 2620 OID 21083)
-- Name: larcauth_termsubject_has_homework trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_termsubject_has_homework FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4419 (class 2620 OID 21065)
-- Name: larcauth_unit trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_unit FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4424 (class 2620 OID 21066)
-- Name: larcauth_unit_period trg_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync BEFORE UPDATE ON public.larcauth_unit_period FOR EACH ROW EXECUTE FUNCTION public.fn_sync_log();


--
-- TOC entry 4184 (class 2620 OID 20925)
-- Name: larcauth_academicyear trg_update_track_larcauth_academicyear; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_academicyear BEFORE UPDATE ON public.larcauth_academicyear FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4189 (class 2620 OID 20930)
-- Name: larcauth_aecuser trg_update_track_larcauth_aecuser; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_aecuser BEFORE UPDATE ON public.larcauth_aecuser FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4193 (class 2620 OID 20943)
-- Name: larcauth_agenda trg_update_track_larcauth_agenda; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_agenda BEFORE UPDATE ON public.larcauth_agenda FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4198 (class 2620 OID 20931)
-- Name: larcauth_campus trg_update_track_larcauth_campus; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_campus BEFORE UPDATE ON public.larcauth_campus FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4203 (class 2620 OID 20929)
-- Name: larcauth_classroom trg_update_track_larcauth_classroom; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_classroom BEFORE UPDATE ON public.larcauth_classroom FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4208 (class 2620 OID 20944)
-- Name: larcauth_classroom_has_timeperiod trg_update_track_larcauth_classroom_has_timeperiod; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_classroom_has_timeperiod BEFORE UPDATE ON public.larcauth_classroom_has_timeperiod FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4213 (class 2620 OID 20934)
-- Name: larcauth_classroom_termothersubject trg_update_track_larcauth_classroom_termothersubject; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_classroom_termothersubject BEFORE UPDATE ON public.larcauth_classroom_termothersubject FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4218 (class 2620 OID 20935)
-- Name: larcauth_classroom_termsubject trg_update_track_larcauth_classroom_termsubject; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_classroom_termsubject BEFORE UPDATE ON public.larcauth_classroom_termsubject FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4222 (class 2620 OID 20936)
-- Name: larcauth_concept trg_update_track_larcauth_concept; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_concept BEFORE UPDATE ON public.larcauth_concept FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4227 (class 2620 OID 20946)
-- Name: larcauth_criteria_of_levelsubject trg_update_track_larcauth_criteria_of_levelsubject; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_criteria_of_levelsubject BEFORE UPDATE ON public.larcauth_criteria_of_levelsubject FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4231 (class 2620 OID 20932)
-- Name: larcauth_criteria_of_subjectsgroup trg_update_track_larcauth_criteria_of_subjectsgroup; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_criteria_of_subjectsgroup BEFORE UPDATE ON public.larcauth_criteria_of_subjectsgroup FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4235 (class 2620 OID 20920)
-- Name: larcauth_district trg_update_track_larcauth_district; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_district BEFORE UPDATE ON public.larcauth_district FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4240 (class 2620 OID 20933)
-- Name: larcauth_edt_classe trg_update_track_larcauth_edt_classe; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_edt_classe BEFORE UPDATE ON public.larcauth_edt_classe FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4245 (class 2620 OID 20945)
-- Name: larcauth_evaluation trg_update_track_larcauth_evaluation; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_evaluation BEFORE UPDATE ON public.larcauth_evaluation FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4249 (class 2620 OID 20927)
-- Name: larcauth_gender trg_update_track_larcauth_gender; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_gender BEFORE UPDATE ON public.larcauth_gender FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4253 (class 2620 OID 20923)
-- Name: larcauth_globalcontext trg_update_track_larcauth_globalcontext; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_globalcontext BEFORE UPDATE ON public.larcauth_globalcontext FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4257 (class 2620 OID 20928)
-- Name: larcauth_language trg_update_track_larcauth_language; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_language BEFORE UPDATE ON public.larcauth_language FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4262 (class 2620 OID 20941)
-- Name: larcauth_learner_has_subjectgroup trg_update_track_larcauth_learner_has_subjectgroup; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learner_has_subjectgroup BEFORE UPDATE ON public.larcauth_learner_has_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4267 (class 2620 OID 20940)
-- Name: larcauth_learner_has_term trg_update_track_larcauth_learner_has_term; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learner_has_term BEFORE UPDATE ON public.larcauth_learner_has_term FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4272 (class 2620 OID 20938)
-- Name: larcauth_learner_has_termothersubject trg_update_track_larcauth_learner_has_termothersubject; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learner_has_termothersubject BEFORE UPDATE ON public.larcauth_learner_has_termothersubject FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4277 (class 2620 OID 20939)
-- Name: larcauth_learner_has_termsubject trg_update_track_larcauth_learner_has_termsubject; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learner_has_termsubject BEFORE UPDATE ON public.larcauth_learner_has_termsubject FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4282 (class 2620 OID 20947)
-- Name: larcauth_learnerdp_has_termsubjectdp trg_update_track_larcauth_learnerdp_has_termsubjectdp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learnerdp_has_termsubjectdp BEFORE UPDATE ON public.larcauth_learnerdp_has_termsubjectdp FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4287 (class 2620 OID 20937)
-- Name: larcauth_learnermat_has_devpers_unit trg_update_track_larcauth_learnermat_has_devpers_unit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learnermat_has_devpers_unit BEFORE UPDATE ON public.larcauth_learnermat_has_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4292 (class 2620 OID 20948)
-- Name: larcauth_learnermat_has_subjectevals_unit trg_update_track_larcauth_learnermat_has_subjectevals_unit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learnermat_has_subjectevals_unit BEFORE UPDATE ON public.larcauth_learnermat_has_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4297 (class 2620 OID 20953)
-- Name: larcauth_learnermat_has_unit_period trg_update_track_larcauth_learnermat_has_unit_period; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learnermat_has_unit_period BEFORE UPDATE ON public.larcauth_learnermat_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4302 (class 2620 OID 20950)
-- Name: larcauth_learnerpei_has_termsubjectpei trg_update_track_larcauth_learnerpei_has_termsubjectpei; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learnerpei_has_termsubjectpei BEFORE UPDATE ON public.larcauth_learnerpei_has_termsubjectpei FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4307 (class 2620 OID 20949)
-- Name: larcauth_learnerpp_has_termsubjectpp trg_update_track_larcauth_learnerpp_has_termsubjectpp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learnerpp_has_termsubjectpp BEFORE UPDATE ON public.larcauth_learnerpp_has_termsubjectpp FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4312 (class 2620 OID 20942)
-- Name: larcauth_learnerprim_has_unit_period trg_update_track_larcauth_learnerprim_has_unit_period; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_learnerprim_has_unit_period BEFORE UPDATE ON public.larcauth_learnerprim_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4317 (class 2620 OID 20924)
-- Name: larcauth_level trg_update_track_larcauth_level; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_level BEFORE UPDATE ON public.larcauth_level FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4322 (class 2620 OID 20951)
-- Name: larcauth_levelsubject trg_update_track_larcauth_levelsubject; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_levelsubject BEFORE UPDATE ON public.larcauth_levelsubject FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4326 (class 2620 OID 20955)
-- Name: larcauth_lieu trg_update_track_larcauth_lieu; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_lieu BEFORE UPDATE ON public.larcauth_lieu FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4330 (class 2620 OID 20954)
-- Name: larcauth_mat_devpers_gene trg_update_track_larcauth_mat_devpers_gene; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_mat_devpers_gene BEFORE UPDATE ON public.larcauth_mat_devpers_gene FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4335 (class 2620 OID 20952)
-- Name: larcauth_mat_devpers_unit trg_update_track_larcauth_mat_devpers_unit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_mat_devpers_unit BEFORE UPDATE ON public.larcauth_mat_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4340 (class 2620 OID 20960)
-- Name: larcauth_mat_subjectevals_unit trg_update_track_larcauth_mat_subjectevals_unit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_mat_subjectevals_unit BEFORE UPDATE ON public.larcauth_mat_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4344 (class 2620 OID 20962)
-- Name: larcauth_mat_subjectskills trg_update_track_larcauth_mat_subjectskills; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_mat_subjectskills BEFORE UPDATE ON public.larcauth_mat_subjectskills FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4349 (class 2620 OID 20961)
-- Name: larcauth_mat_subjectskills_unit trg_update_track_larcauth_mat_subjectskills_unit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_mat_subjectskills_unit BEFORE UPDATE ON public.larcauth_mat_subjectskills_unit FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4354 (class 2620 OID 20963)
-- Name: larcauth_mat_unit trg_update_track_larcauth_mat_unit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_mat_unit BEFORE UPDATE ON public.larcauth_mat_unit FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4358 (class 2620 OID 20966)
-- Name: larcauth_natureparentutor trg_update_track_larcauth_natureparentutor; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_natureparentutor BEFORE UPDATE ON public.larcauth_natureparentutor FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4362 (class 2620 OID 20926)
-- Name: larcauth_program trg_update_track_larcauth_program; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_program BEFORE UPDATE ON public.larcauth_program FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4367 (class 2620 OID 20965)
-- Name: larcauth_student trg_update_track_larcauth_student; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_student BEFORE UPDATE ON public.larcauth_student FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4372 (class 2620 OID 20959)
-- Name: larcauth_student_has_dayevents trg_update_track_larcauth_student_has_dayevents; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_student_has_dayevents BEFORE UPDATE ON public.larcauth_student_has_dayevents FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4377 (class 2620 OID 20958)
-- Name: larcauth_student_has_events trg_update_track_larcauth_student_has_events; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_student_has_events BEFORE UPDATE ON public.larcauth_student_has_events FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4382 (class 2620 OID 20957)
-- Name: larcauth_student_has_termevents trg_update_track_larcauth_student_has_termevents; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_student_has_termevents BEFORE UPDATE ON public.larcauth_student_has_termevents FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4387 (class 2620 OID 20956)
-- Name: larcauth_student_has_weekevents trg_update_track_larcauth_student_has_weekevents; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_student_has_weekevents BEFORE UPDATE ON public.larcauth_student_has_weekevents FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4392 (class 2620 OID 20967)
-- Name: larcauth_subjectgroup trg_update_track_larcauth_subjectgroup; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_subjectgroup BEFORE UPDATE ON public.larcauth_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4429 (class 2620 OID 20972)
-- Name: larcauth_sync_log trg_update_track_larcauth_sync_log; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_sync_log BEFORE UPDATE ON public.larcauth_sync_log FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4397 (class 2620 OID 20964)
-- Name: larcauth_teachadm trg_update_track_larcauth_teachadm; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_teachadm BEFORE UPDATE ON public.larcauth_teachadm FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4402 (class 2620 OID 20971)
-- Name: larcauth_term trg_update_track_larcauth_term; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_term BEFORE UPDATE ON public.larcauth_term FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4407 (class 2620 OID 20921)
-- Name: larcauth_termsubject_has_homework trg_update_track_larcauth_termsubject_has_homework; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_termsubject_has_homework BEFORE UPDATE ON public.larcauth_termsubject_has_homework FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4411 (class 2620 OID 20969)
-- Name: larcauth_timeperiod trg_update_track_larcauth_timeperiod; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_timeperiod BEFORE UPDATE ON public.larcauth_timeperiod FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4415 (class 2620 OID 20968)
-- Name: larcauth_type_event trg_update_track_larcauth_type_event; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_type_event BEFORE UPDATE ON public.larcauth_type_event FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4420 (class 2620 OID 20922)
-- Name: larcauth_unit trg_update_track_larcauth_unit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_unit BEFORE UPDATE ON public.larcauth_unit FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4425 (class 2620 OID 20970)
-- Name: larcauth_unit_period trg_update_track_larcauth_unit_period; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_track_larcauth_unit_period BEFORE UPDATE ON public.larcauth_unit_period FOR EACH ROW EXECUTE FUNCTION public.fn_track_updates();


--
-- TOC entry 4185 (class 2620 OID 20718)
-- Name: larcauth_academicyear update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_academicyear FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4190 (class 2620 OID 20733)
-- Name: larcauth_aecuser update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_aecuser FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4194 (class 2620 OID 20772)
-- Name: larcauth_agenda update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_agenda FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4199 (class 2620 OID 20736)
-- Name: larcauth_campus update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_campus FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4204 (class 2620 OID 20730)
-- Name: larcauth_classroom update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_classroom FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4209 (class 2620 OID 20775)
-- Name: larcauth_classroom_has_timeperiod update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_classroom_has_timeperiod FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4214 (class 2620 OID 20745)
-- Name: larcauth_classroom_termothersubject update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_classroom_termothersubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4219 (class 2620 OID 20748)
-- Name: larcauth_classroom_termsubject update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_classroom_termsubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4223 (class 2620 OID 20751)
-- Name: larcauth_concept update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_concept FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4228 (class 2620 OID 20781)
-- Name: larcauth_criteria_of_levelsubject update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_criteria_of_levelsubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4232 (class 2620 OID 20739)
-- Name: larcauth_criteria_of_subjectsgroup update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_criteria_of_subjectsgroup FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4236 (class 2620 OID 20703)
-- Name: larcauth_district update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_district FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4241 (class 2620 OID 20742)
-- Name: larcauth_edt_classe update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_edt_classe FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4246 (class 2620 OID 20778)
-- Name: larcauth_evaluation update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_evaluation FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4250 (class 2620 OID 20724)
-- Name: larcauth_gender update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_gender FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4254 (class 2620 OID 20712)
-- Name: larcauth_globalcontext update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_globalcontext FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4258 (class 2620 OID 20727)
-- Name: larcauth_language update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_language FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4263 (class 2620 OID 20766)
-- Name: larcauth_learner_has_subjectgroup update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learner_has_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4268 (class 2620 OID 20763)
-- Name: larcauth_learner_has_term update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learner_has_term FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4273 (class 2620 OID 20757)
-- Name: larcauth_learner_has_termothersubject update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learner_has_termothersubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4278 (class 2620 OID 20760)
-- Name: larcauth_learner_has_termsubject update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learner_has_termsubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4283 (class 2620 OID 20784)
-- Name: larcauth_learnerdp_has_termsubjectdp update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learnerdp_has_termsubjectdp FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4288 (class 2620 OID 20754)
-- Name: larcauth_learnermat_has_devpers_unit update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learnermat_has_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4293 (class 2620 OID 20787)
-- Name: larcauth_learnermat_has_subjectevals_unit update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learnermat_has_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4298 (class 2620 OID 20802)
-- Name: larcauth_learnermat_has_unit_period update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learnermat_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4303 (class 2620 OID 20793)
-- Name: larcauth_learnerpei_has_termsubjectpei update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learnerpei_has_termsubjectpei FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4308 (class 2620 OID 20790)
-- Name: larcauth_learnerpp_has_termsubjectpp update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learnerpp_has_termsubjectpp FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4313 (class 2620 OID 20769)
-- Name: larcauth_learnerprim_has_unit_period update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_learnerprim_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4318 (class 2620 OID 20715)
-- Name: larcauth_level update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_level FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4323 (class 2620 OID 20796)
-- Name: larcauth_levelsubject update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_levelsubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4327 (class 2620 OID 20808)
-- Name: larcauth_lieu update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_lieu FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4331 (class 2620 OID 20805)
-- Name: larcauth_mat_devpers_gene update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_mat_devpers_gene FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4336 (class 2620 OID 20799)
-- Name: larcauth_mat_devpers_unit update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_mat_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4341 (class 2620 OID 20823)
-- Name: larcauth_mat_subjectevals_unit update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_mat_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4345 (class 2620 OID 20829)
-- Name: larcauth_mat_subjectskills update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_mat_subjectskills FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4350 (class 2620 OID 20826)
-- Name: larcauth_mat_subjectskills_unit update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_mat_subjectskills_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4355 (class 2620 OID 20832)
-- Name: larcauth_mat_unit update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_mat_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4359 (class 2620 OID 20841)
-- Name: larcauth_natureparentutor update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_natureparentutor FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4363 (class 2620 OID 20721)
-- Name: larcauth_program update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_program FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4368 (class 2620 OID 20838)
-- Name: larcauth_student update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_student FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4373 (class 2620 OID 20820)
-- Name: larcauth_student_has_dayevents update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_student_has_dayevents FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4378 (class 2620 OID 20817)
-- Name: larcauth_student_has_events update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_student_has_events FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4383 (class 2620 OID 20814)
-- Name: larcauth_student_has_termevents update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_student_has_termevents FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4388 (class 2620 OID 20811)
-- Name: larcauth_student_has_weekevents update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_student_has_weekevents FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4393 (class 2620 OID 20844)
-- Name: larcauth_subjectgroup update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4430 (class 2620 OID 18797)
-- Name: larcauth_sync_log update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_sync_log FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4398 (class 2620 OID 20835)
-- Name: larcauth_teachadm update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_teachadm FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4403 (class 2620 OID 20856)
-- Name: larcauth_term update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_term FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4408 (class 2620 OID 20706)
-- Name: larcauth_termsubject_has_homework update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_termsubject_has_homework FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4412 (class 2620 OID 20850)
-- Name: larcauth_timeperiod update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_timeperiod FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4416 (class 2620 OID 20847)
-- Name: larcauth_type_event update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_type_event FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4421 (class 2620 OID 20709)
-- Name: larcauth_unit update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4426 (class 2620 OID 20853)
-- Name: larcauth_unit_period update_sync_version; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_sync_version BEFORE UPDATE ON public.larcauth_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4186 (class 2620 OID 20717)
-- Name: larcauth_academicyear update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_academicyear FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4191 (class 2620 OID 20732)
-- Name: larcauth_aecuser update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_aecuser FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4195 (class 2620 OID 20771)
-- Name: larcauth_agenda update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_agenda FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4200 (class 2620 OID 20735)
-- Name: larcauth_campus update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_campus FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4205 (class 2620 OID 20729)
-- Name: larcauth_classroom update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_classroom FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4210 (class 2620 OID 20774)
-- Name: larcauth_classroom_has_timeperiod update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_classroom_has_timeperiod FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4215 (class 2620 OID 20744)
-- Name: larcauth_classroom_termothersubject update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_classroom_termothersubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4220 (class 2620 OID 20747)
-- Name: larcauth_classroom_termsubject update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_classroom_termsubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4224 (class 2620 OID 20750)
-- Name: larcauth_concept update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_concept FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4229 (class 2620 OID 20780)
-- Name: larcauth_criteria_of_levelsubject update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_criteria_of_levelsubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4233 (class 2620 OID 20738)
-- Name: larcauth_criteria_of_subjectsgroup update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_criteria_of_subjectsgroup FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4237 (class 2620 OID 20702)
-- Name: larcauth_district update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_district FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4242 (class 2620 OID 20741)
-- Name: larcauth_edt_classe update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_edt_classe FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4247 (class 2620 OID 20777)
-- Name: larcauth_evaluation update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_evaluation FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4251 (class 2620 OID 20723)
-- Name: larcauth_gender update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_gender FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4255 (class 2620 OID 20711)
-- Name: larcauth_globalcontext update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_globalcontext FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4259 (class 2620 OID 20726)
-- Name: larcauth_language update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_language FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4264 (class 2620 OID 20765)
-- Name: larcauth_learner_has_subjectgroup update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learner_has_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4269 (class 2620 OID 20762)
-- Name: larcauth_learner_has_term update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learner_has_term FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4274 (class 2620 OID 20756)
-- Name: larcauth_learner_has_termothersubject update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learner_has_termothersubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4279 (class 2620 OID 20759)
-- Name: larcauth_learner_has_termsubject update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learner_has_termsubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4284 (class 2620 OID 20783)
-- Name: larcauth_learnerdp_has_termsubjectdp update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learnerdp_has_termsubjectdp FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4289 (class 2620 OID 20753)
-- Name: larcauth_learnermat_has_devpers_unit update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learnermat_has_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4294 (class 2620 OID 20786)
-- Name: larcauth_learnermat_has_subjectevals_unit update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learnermat_has_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4299 (class 2620 OID 20801)
-- Name: larcauth_learnermat_has_unit_period update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learnermat_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4304 (class 2620 OID 20792)
-- Name: larcauth_learnerpei_has_termsubjectpei update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learnerpei_has_termsubjectpei FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4309 (class 2620 OID 20789)
-- Name: larcauth_learnerpp_has_termsubjectpp update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learnerpp_has_termsubjectpp FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4314 (class 2620 OID 20768)
-- Name: larcauth_learnerprim_has_unit_period update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_learnerprim_has_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4319 (class 2620 OID 20714)
-- Name: larcauth_level update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_level FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4324 (class 2620 OID 20795)
-- Name: larcauth_levelsubject update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_levelsubject FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4328 (class 2620 OID 20807)
-- Name: larcauth_lieu update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_lieu FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4332 (class 2620 OID 20804)
-- Name: larcauth_mat_devpers_gene update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_mat_devpers_gene FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4337 (class 2620 OID 20798)
-- Name: larcauth_mat_devpers_unit update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_mat_devpers_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4342 (class 2620 OID 20822)
-- Name: larcauth_mat_subjectevals_unit update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_mat_subjectevals_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4346 (class 2620 OID 20828)
-- Name: larcauth_mat_subjectskills update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_mat_subjectskills FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4351 (class 2620 OID 20825)
-- Name: larcauth_mat_subjectskills_unit update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_mat_subjectskills_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4356 (class 2620 OID 20831)
-- Name: larcauth_mat_unit update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_mat_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4360 (class 2620 OID 20840)
-- Name: larcauth_natureparentutor update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_natureparentutor FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4364 (class 2620 OID 20720)
-- Name: larcauth_program update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_program FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4369 (class 2620 OID 20837)
-- Name: larcauth_student update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_student FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4374 (class 2620 OID 20819)
-- Name: larcauth_student_has_dayevents update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_student_has_dayevents FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4379 (class 2620 OID 20816)
-- Name: larcauth_student_has_events update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_student_has_events FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4384 (class 2620 OID 20813)
-- Name: larcauth_student_has_termevents update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_student_has_termevents FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4389 (class 2620 OID 20810)
-- Name: larcauth_student_has_weekevents update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_student_has_weekevents FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4394 (class 2620 OID 20843)
-- Name: larcauth_subjectgroup update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_subjectgroup FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4431 (class 2620 OID 18796)
-- Name: larcauth_sync_log update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_sync_log FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4399 (class 2620 OID 20834)
-- Name: larcauth_teachadm update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_teachadm FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4404 (class 2620 OID 20855)
-- Name: larcauth_term update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_term FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4409 (class 2620 OID 20705)
-- Name: larcauth_termsubject_has_homework update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_termsubject_has_homework FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4413 (class 2620 OID 20849)
-- Name: larcauth_timeperiod update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_timeperiod FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4417 (class 2620 OID 20846)
-- Name: larcauth_type_event update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_type_event FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4422 (class 2620 OID 20708)
-- Name: larcauth_unit update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_unit FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4427 (class 2620 OID 20852)
-- Name: larcauth_unit_period update_updated_at_column; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_updated_at_column BEFORE UPDATE ON public.larcauth_unit_period FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at_and_sync();


--
-- TOC entry 4580 (class 0 OID 17413)
-- Dependencies: 327
-- Name: larcauth_academicyear; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_academicyear ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4581 (class 0 OID 17417)
-- Dependencies: 328
-- Name: larcauth_aecuser; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_aecuser ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4582 (class 0 OID 17422)
-- Dependencies: 329
-- Name: larcauth_agenda; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_agenda ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4583 (class 0 OID 17436)
-- Dependencies: 330
-- Name: larcauth_campus; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_campus ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4584 (class 0 OID 17441)
-- Dependencies: 331
-- Name: larcauth_classroom; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_classroom ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4585 (class 0 OID 17446)
-- Dependencies: 332
-- Name: larcauth_classroom_has_timeperiod; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_classroom_has_timeperiod ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4586 (class 0 OID 17451)
-- Dependencies: 333
-- Name: larcauth_classroom_termothersubject; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_classroom_termothersubject ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4587 (class 0 OID 17456)
-- Dependencies: 334
-- Name: larcauth_classroom_termsubject; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_classroom_termsubject ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4588 (class 0 OID 17462)
-- Dependencies: 335
-- Name: larcauth_concept; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_concept ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4589 (class 0 OID 17465)
-- Dependencies: 336
-- Name: larcauth_criteria_of_levelsubject; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_criteria_of_levelsubject ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4590 (class 0 OID 17470)
-- Dependencies: 337
-- Name: larcauth_criteria_of_subjectsgroup; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_criteria_of_subjectsgroup ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4591 (class 0 OID 17475)
-- Dependencies: 338
-- Name: larcauth_district; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_district ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4592 (class 0 OID 17478)
-- Dependencies: 339
-- Name: larcauth_edt_classe; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_edt_classe ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4593 (class 0 OID 17483)
-- Dependencies: 340
-- Name: larcauth_evaluation; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_evaluation ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4594 (class 0 OID 17486)
-- Dependencies: 341
-- Name: larcauth_gender; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_gender ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4595 (class 0 OID 17489)
-- Dependencies: 342
-- Name: larcauth_globalcontext; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_globalcontext ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4596 (class 0 OID 17494)
-- Dependencies: 343
-- Name: larcauth_language; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_language ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4597 (class 0 OID 17497)
-- Dependencies: 344
-- Name: larcauth_learner_has_subjectgroup; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learner_has_subjectgroup ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4598 (class 0 OID 17502)
-- Dependencies: 345
-- Name: larcauth_learner_has_term; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learner_has_term ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4599 (class 0 OID 17507)
-- Dependencies: 346
-- Name: larcauth_learner_has_termothersubject; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learner_has_termothersubject ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4600 (class 0 OID 17512)
-- Dependencies: 347
-- Name: larcauth_learner_has_termsubject; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learner_has_termsubject ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4601 (class 0 OID 17515)
-- Dependencies: 348
-- Name: larcauth_learnerdp_has_termsubjectdp; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learnerdp_has_termsubjectdp ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4602 (class 0 OID 17520)
-- Dependencies: 349
-- Name: larcauth_learnermat_has_devpers_unit; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learnermat_has_devpers_unit ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4603 (class 0 OID 17524)
-- Dependencies: 350
-- Name: larcauth_learnermat_has_subjectevals_unit; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learnermat_has_subjectevals_unit ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4604 (class 0 OID 17530)
-- Dependencies: 351
-- Name: larcauth_learnermat_has_unit_period; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learnermat_has_unit_period ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4605 (class 0 OID 17561)
-- Dependencies: 352
-- Name: larcauth_learnerpei_has_termsubjectpei; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learnerpei_has_termsubjectpei ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4606 (class 0 OID 17566)
-- Dependencies: 353
-- Name: larcauth_learnerpp_has_termsubjectpp; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learnerpp_has_termsubjectpp ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4607 (class 0 OID 17571)
-- Dependencies: 354
-- Name: larcauth_learnerprim_has_unit_period; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_learnerprim_has_unit_period ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4608 (class 0 OID 17586)
-- Dependencies: 355
-- Name: larcauth_level; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_level ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4609 (class 0 OID 17591)
-- Dependencies: 356
-- Name: larcauth_levelsubject; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_levelsubject ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4610 (class 0 OID 17596)
-- Dependencies: 357
-- Name: larcauth_lieu; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_lieu ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4611 (class 0 OID 17599)
-- Dependencies: 358
-- Name: larcauth_mat_devpers_gene; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_mat_devpers_gene ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4612 (class 0 OID 17604)
-- Dependencies: 359
-- Name: larcauth_mat_devpers_unit; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_mat_devpers_unit ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4613 (class 0 OID 17610)
-- Dependencies: 360
-- Name: larcauth_mat_subjectevals_unit; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_mat_subjectevals_unit ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4614 (class 0 OID 17616)
-- Dependencies: 361
-- Name: larcauth_mat_subjectskills; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_mat_subjectskills ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4615 (class 0 OID 17621)
-- Dependencies: 362
-- Name: larcauth_mat_subjectskills_unit; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_mat_subjectskills_unit ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4616 (class 0 OID 17627)
-- Dependencies: 363
-- Name: larcauth_mat_unit; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_mat_unit ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4617 (class 0 OID 17637)
-- Dependencies: 364
-- Name: larcauth_natureparentutor; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_natureparentutor ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4618 (class 0 OID 17640)
-- Dependencies: 365
-- Name: larcauth_program; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_program ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4619 (class 0 OID 17643)
-- Dependencies: 366
-- Name: larcauth_student; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_student ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4620 (class 0 OID 17646)
-- Dependencies: 367
-- Name: larcauth_student_has_dayevents; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_student_has_dayevents ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4621 (class 0 OID 17650)
-- Dependencies: 368
-- Name: larcauth_student_has_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_student_has_events ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4622 (class 0 OID 17654)
-- Dependencies: 369
-- Name: larcauth_student_has_termevents; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_student_has_termevents ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4623 (class 0 OID 17657)
-- Dependencies: 370
-- Name: larcauth_student_has_weekevents; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_student_has_weekevents ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4624 (class 0 OID 17660)
-- Dependencies: 371
-- Name: larcauth_subjectgroup; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_subjectgroup ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4632 (class 0 OID 18629)
-- Dependencies: 387
-- Name: larcauth_sync_log; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_sync_log ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4625 (class 0 OID 17665)
-- Dependencies: 372
-- Name: larcauth_teachadm; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_teachadm ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4626 (class 0 OID 17668)
-- Dependencies: 373
-- Name: larcauth_term; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_term ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4627 (class 0 OID 17671)
-- Dependencies: 374
-- Name: larcauth_termsubject_has_homework; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_termsubject_has_homework ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4628 (class 0 OID 17676)
-- Dependencies: 375
-- Name: larcauth_timeperiod; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_timeperiod ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4629 (class 0 OID 17679)
-- Dependencies: 376
-- Name: larcauth_type_event; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_type_event ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4630 (class 0 OID 17683)
-- Dependencies: 377
-- Name: larcauth_unit; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_unit ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4631 (class 0 OID 17742)
-- Dependencies: 378
-- Name: larcauth_unit_period; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.larcauth_unit_period ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4634 (class 0 OID 20984)
-- Dependencies: 390
-- Name: sync_log; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sync_log ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4633 (class 0 OID 20973)
-- Dependencies: 388
-- Name: sync_state; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sync_state ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4635 (class 0 OID 20998)
-- Dependencies: 391
-- Name: sync_table_config; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.sync_table_config ENABLE ROW LEVEL SECURITY;

--
-- TOC entry 4643 (class 0 OID 0)
-- Dependencies: 28
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- TOC entry 4645 (class 0 OID 0)
-- Dependencies: 503
-- Name: FUNCTION fn_sync_log(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_sync_log() TO anon;
GRANT ALL ON FUNCTION public.fn_sync_log() TO authenticated;
GRANT ALL ON FUNCTION public.fn_sync_log() TO service_role;


--
-- TOC entry 4646 (class 0 OID 0)
-- Dependencies: 502
-- Name: FUNCTION fn_track_updates(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_track_updates() TO anon;
GRANT ALL ON FUNCTION public.fn_track_updates() TO authenticated;
GRANT ALL ON FUNCTION public.fn_track_updates() TO service_role;


--
-- TOC entry 4647 (class 0 OID 0)
-- Dependencies: 501
-- Name: FUNCTION handle_sync_log(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.handle_sync_log() TO anon;
GRANT ALL ON FUNCTION public.handle_sync_log() TO authenticated;
GRANT ALL ON FUNCTION public.handle_sync_log() TO service_role;


--
-- TOC entry 4648 (class 0 OID 0)
-- Dependencies: 500
-- Name: FUNCTION handle_updated_at_and_sync(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.handle_updated_at_and_sync() TO anon;
GRANT ALL ON FUNCTION public.handle_updated_at_and_sync() TO authenticated;
GRANT ALL ON FUNCTION public.handle_updated_at_and_sync() TO service_role;


--
-- TOC entry 4649 (class 0 OID 0)
-- Dependencies: 469
-- Name: FUNCTION rls_auto_enable(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.rls_auto_enable() TO anon;
GRANT ALL ON FUNCTION public.rls_auto_enable() TO authenticated;
GRANT ALL ON FUNCTION public.rls_auto_enable() TO service_role;


--
-- TOC entry 4650 (class 0 OID 0)
-- Dependencies: 327
-- Name: TABLE larcauth_academicyear; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_academicyear TO anon;
GRANT ALL ON TABLE public.larcauth_academicyear TO authenticated;
GRANT ALL ON TABLE public.larcauth_academicyear TO service_role;


--
-- TOC entry 4651 (class 0 OID 0)
-- Dependencies: 328
-- Name: TABLE larcauth_aecuser; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_aecuser TO anon;
GRANT ALL ON TABLE public.larcauth_aecuser TO authenticated;
GRANT ALL ON TABLE public.larcauth_aecuser TO service_role;


--
-- TOC entry 4652 (class 0 OID 0)
-- Dependencies: 329
-- Name: TABLE larcauth_agenda; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_agenda TO anon;
GRANT ALL ON TABLE public.larcauth_agenda TO authenticated;
GRANT ALL ON TABLE public.larcauth_agenda TO service_role;


--
-- TOC entry 4653 (class 0 OID 0)
-- Dependencies: 330
-- Name: TABLE larcauth_campus; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_campus TO anon;
GRANT ALL ON TABLE public.larcauth_campus TO authenticated;
GRANT ALL ON TABLE public.larcauth_campus TO service_role;


--
-- TOC entry 4654 (class 0 OID 0)
-- Dependencies: 331
-- Name: TABLE larcauth_classroom; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_classroom TO anon;
GRANT ALL ON TABLE public.larcauth_classroom TO authenticated;
GRANT ALL ON TABLE public.larcauth_classroom TO service_role;


--
-- TOC entry 4655 (class 0 OID 0)
-- Dependencies: 332
-- Name: TABLE larcauth_classroom_has_timeperiod; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_classroom_has_timeperiod TO anon;
GRANT ALL ON TABLE public.larcauth_classroom_has_timeperiod TO authenticated;
GRANT ALL ON TABLE public.larcauth_classroom_has_timeperiod TO service_role;


--
-- TOC entry 4656 (class 0 OID 0)
-- Dependencies: 333
-- Name: TABLE larcauth_classroom_termothersubject; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_classroom_termothersubject TO anon;
GRANT ALL ON TABLE public.larcauth_classroom_termothersubject TO authenticated;
GRANT ALL ON TABLE public.larcauth_classroom_termothersubject TO service_role;


--
-- TOC entry 4657 (class 0 OID 0)
-- Dependencies: 334
-- Name: TABLE larcauth_classroom_termsubject; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_classroom_termsubject TO anon;
GRANT ALL ON TABLE public.larcauth_classroom_termsubject TO authenticated;
GRANT ALL ON TABLE public.larcauth_classroom_termsubject TO service_role;


--
-- TOC entry 4658 (class 0 OID 0)
-- Dependencies: 335
-- Name: TABLE larcauth_concept; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_concept TO anon;
GRANT ALL ON TABLE public.larcauth_concept TO authenticated;
GRANT ALL ON TABLE public.larcauth_concept TO service_role;


--
-- TOC entry 4659 (class 0 OID 0)
-- Dependencies: 336
-- Name: TABLE larcauth_criteria_of_levelsubject; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_criteria_of_levelsubject TO anon;
GRANT ALL ON TABLE public.larcauth_criteria_of_levelsubject TO authenticated;
GRANT ALL ON TABLE public.larcauth_criteria_of_levelsubject TO service_role;


--
-- TOC entry 4660 (class 0 OID 0)
-- Dependencies: 337
-- Name: TABLE larcauth_criteria_of_subjectsgroup; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_criteria_of_subjectsgroup TO anon;
GRANT ALL ON TABLE public.larcauth_criteria_of_subjectsgroup TO authenticated;
GRANT ALL ON TABLE public.larcauth_criteria_of_subjectsgroup TO service_role;


--
-- TOC entry 4661 (class 0 OID 0)
-- Dependencies: 338
-- Name: TABLE larcauth_district; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_district TO anon;
GRANT ALL ON TABLE public.larcauth_district TO authenticated;
GRANT ALL ON TABLE public.larcauth_district TO service_role;


--
-- TOC entry 4662 (class 0 OID 0)
-- Dependencies: 339
-- Name: TABLE larcauth_edt_classe; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_edt_classe TO anon;
GRANT ALL ON TABLE public.larcauth_edt_classe TO authenticated;
GRANT ALL ON TABLE public.larcauth_edt_classe TO service_role;


--
-- TOC entry 4663 (class 0 OID 0)
-- Dependencies: 340
-- Name: TABLE larcauth_evaluation; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_evaluation TO anon;
GRANT ALL ON TABLE public.larcauth_evaluation TO authenticated;
GRANT ALL ON TABLE public.larcauth_evaluation TO service_role;


--
-- TOC entry 4664 (class 0 OID 0)
-- Dependencies: 341
-- Name: TABLE larcauth_gender; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_gender TO anon;
GRANT ALL ON TABLE public.larcauth_gender TO authenticated;
GRANT ALL ON TABLE public.larcauth_gender TO service_role;


--
-- TOC entry 4665 (class 0 OID 0)
-- Dependencies: 342
-- Name: TABLE larcauth_globalcontext; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_globalcontext TO anon;
GRANT ALL ON TABLE public.larcauth_globalcontext TO authenticated;
GRANT ALL ON TABLE public.larcauth_globalcontext TO service_role;


--
-- TOC entry 4666 (class 0 OID 0)
-- Dependencies: 343
-- Name: TABLE larcauth_language; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_language TO anon;
GRANT ALL ON TABLE public.larcauth_language TO authenticated;
GRANT ALL ON TABLE public.larcauth_language TO service_role;


--
-- TOC entry 4667 (class 0 OID 0)
-- Dependencies: 344
-- Name: TABLE larcauth_learner_has_subjectgroup; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learner_has_subjectgroup TO anon;
GRANT ALL ON TABLE public.larcauth_learner_has_subjectgroup TO authenticated;
GRANT ALL ON TABLE public.larcauth_learner_has_subjectgroup TO service_role;


--
-- TOC entry 4668 (class 0 OID 0)
-- Dependencies: 345
-- Name: TABLE larcauth_learner_has_term; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learner_has_term TO anon;
GRANT ALL ON TABLE public.larcauth_learner_has_term TO authenticated;
GRANT ALL ON TABLE public.larcauth_learner_has_term TO service_role;


--
-- TOC entry 4669 (class 0 OID 0)
-- Dependencies: 346
-- Name: TABLE larcauth_learner_has_termothersubject; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learner_has_termothersubject TO anon;
GRANT ALL ON TABLE public.larcauth_learner_has_termothersubject TO authenticated;
GRANT ALL ON TABLE public.larcauth_learner_has_termothersubject TO service_role;


--
-- TOC entry 4670 (class 0 OID 0)
-- Dependencies: 347
-- Name: TABLE larcauth_learner_has_termsubject; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learner_has_termsubject TO anon;
GRANT ALL ON TABLE public.larcauth_learner_has_termsubject TO authenticated;
GRANT ALL ON TABLE public.larcauth_learner_has_termsubject TO service_role;


--
-- TOC entry 4671 (class 0 OID 0)
-- Dependencies: 348
-- Name: TABLE larcauth_learnerdp_has_termsubjectdp; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learnerdp_has_termsubjectdp TO anon;
GRANT ALL ON TABLE public.larcauth_learnerdp_has_termsubjectdp TO authenticated;
GRANT ALL ON TABLE public.larcauth_learnerdp_has_termsubjectdp TO service_role;


--
-- TOC entry 4672 (class 0 OID 0)
-- Dependencies: 349
-- Name: TABLE larcauth_learnermat_has_devpers_unit; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learnermat_has_devpers_unit TO anon;
GRANT ALL ON TABLE public.larcauth_learnermat_has_devpers_unit TO authenticated;
GRANT ALL ON TABLE public.larcauth_learnermat_has_devpers_unit TO service_role;


--
-- TOC entry 4673 (class 0 OID 0)
-- Dependencies: 350
-- Name: TABLE larcauth_learnermat_has_subjectevals_unit; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learnermat_has_subjectevals_unit TO anon;
GRANT ALL ON TABLE public.larcauth_learnermat_has_subjectevals_unit TO authenticated;
GRANT ALL ON TABLE public.larcauth_learnermat_has_subjectevals_unit TO service_role;


--
-- TOC entry 4674 (class 0 OID 0)
-- Dependencies: 351
-- Name: TABLE larcauth_learnermat_has_unit_period; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learnermat_has_unit_period TO anon;
GRANT ALL ON TABLE public.larcauth_learnermat_has_unit_period TO authenticated;
GRANT ALL ON TABLE public.larcauth_learnermat_has_unit_period TO service_role;


--
-- TOC entry 4675 (class 0 OID 0)
-- Dependencies: 352
-- Name: TABLE larcauth_learnerpei_has_termsubjectpei; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learnerpei_has_termsubjectpei TO anon;
GRANT ALL ON TABLE public.larcauth_learnerpei_has_termsubjectpei TO authenticated;
GRANT ALL ON TABLE public.larcauth_learnerpei_has_termsubjectpei TO service_role;


--
-- TOC entry 4676 (class 0 OID 0)
-- Dependencies: 353
-- Name: TABLE larcauth_learnerpp_has_termsubjectpp; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learnerpp_has_termsubjectpp TO anon;
GRANT ALL ON TABLE public.larcauth_learnerpp_has_termsubjectpp TO authenticated;
GRANT ALL ON TABLE public.larcauth_learnerpp_has_termsubjectpp TO service_role;


--
-- TOC entry 4677 (class 0 OID 0)
-- Dependencies: 354
-- Name: TABLE larcauth_learnerprim_has_unit_period; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_learnerprim_has_unit_period TO anon;
GRANT ALL ON TABLE public.larcauth_learnerprim_has_unit_period TO authenticated;
GRANT ALL ON TABLE public.larcauth_learnerprim_has_unit_period TO service_role;


--
-- TOC entry 4678 (class 0 OID 0)
-- Dependencies: 355
-- Name: TABLE larcauth_level; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_level TO anon;
GRANT ALL ON TABLE public.larcauth_level TO authenticated;
GRANT ALL ON TABLE public.larcauth_level TO service_role;


--
-- TOC entry 4679 (class 0 OID 0)
-- Dependencies: 356
-- Name: TABLE larcauth_levelsubject; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_levelsubject TO anon;
GRANT ALL ON TABLE public.larcauth_levelsubject TO authenticated;
GRANT ALL ON TABLE public.larcauth_levelsubject TO service_role;


--
-- TOC entry 4680 (class 0 OID 0)
-- Dependencies: 357
-- Name: TABLE larcauth_lieu; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_lieu TO anon;
GRANT ALL ON TABLE public.larcauth_lieu TO authenticated;
GRANT ALL ON TABLE public.larcauth_lieu TO service_role;


--
-- TOC entry 4681 (class 0 OID 0)
-- Dependencies: 358
-- Name: TABLE larcauth_mat_devpers_gene; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_mat_devpers_gene TO anon;
GRANT ALL ON TABLE public.larcauth_mat_devpers_gene TO authenticated;
GRANT ALL ON TABLE public.larcauth_mat_devpers_gene TO service_role;


--
-- TOC entry 4682 (class 0 OID 0)
-- Dependencies: 359
-- Name: TABLE larcauth_mat_devpers_unit; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_mat_devpers_unit TO anon;
GRANT ALL ON TABLE public.larcauth_mat_devpers_unit TO authenticated;
GRANT ALL ON TABLE public.larcauth_mat_devpers_unit TO service_role;


--
-- TOC entry 4683 (class 0 OID 0)
-- Dependencies: 360
-- Name: TABLE larcauth_mat_subjectevals_unit; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_mat_subjectevals_unit TO anon;
GRANT ALL ON TABLE public.larcauth_mat_subjectevals_unit TO authenticated;
GRANT ALL ON TABLE public.larcauth_mat_subjectevals_unit TO service_role;


--
-- TOC entry 4684 (class 0 OID 0)
-- Dependencies: 361
-- Name: TABLE larcauth_mat_subjectskills; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_mat_subjectskills TO anon;
GRANT ALL ON TABLE public.larcauth_mat_subjectskills TO authenticated;
GRANT ALL ON TABLE public.larcauth_mat_subjectskills TO service_role;


--
-- TOC entry 4685 (class 0 OID 0)
-- Dependencies: 362
-- Name: TABLE larcauth_mat_subjectskills_unit; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_mat_subjectskills_unit TO anon;
GRANT ALL ON TABLE public.larcauth_mat_subjectskills_unit TO authenticated;
GRANT ALL ON TABLE public.larcauth_mat_subjectskills_unit TO service_role;


--
-- TOC entry 4686 (class 0 OID 0)
-- Dependencies: 363
-- Name: TABLE larcauth_mat_unit; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_mat_unit TO anon;
GRANT ALL ON TABLE public.larcauth_mat_unit TO authenticated;
GRANT ALL ON TABLE public.larcauth_mat_unit TO service_role;


--
-- TOC entry 4687 (class 0 OID 0)
-- Dependencies: 364
-- Name: TABLE larcauth_natureparentutor; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_natureparentutor TO anon;
GRANT ALL ON TABLE public.larcauth_natureparentutor TO authenticated;
GRANT ALL ON TABLE public.larcauth_natureparentutor TO service_role;


--
-- TOC entry 4688 (class 0 OID 0)
-- Dependencies: 365
-- Name: TABLE larcauth_program; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_program TO anon;
GRANT ALL ON TABLE public.larcauth_program TO authenticated;
GRANT ALL ON TABLE public.larcauth_program TO service_role;


--
-- TOC entry 4689 (class 0 OID 0)
-- Dependencies: 366
-- Name: TABLE larcauth_student; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_student TO anon;
GRANT ALL ON TABLE public.larcauth_student TO authenticated;
GRANT ALL ON TABLE public.larcauth_student TO service_role;


--
-- TOC entry 4690 (class 0 OID 0)
-- Dependencies: 367
-- Name: TABLE larcauth_student_has_dayevents; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_student_has_dayevents TO anon;
GRANT ALL ON TABLE public.larcauth_student_has_dayevents TO authenticated;
GRANT ALL ON TABLE public.larcauth_student_has_dayevents TO service_role;


--
-- TOC entry 4691 (class 0 OID 0)
-- Dependencies: 368
-- Name: TABLE larcauth_student_has_events; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_student_has_events TO anon;
GRANT ALL ON TABLE public.larcauth_student_has_events TO authenticated;
GRANT ALL ON TABLE public.larcauth_student_has_events TO service_role;


--
-- TOC entry 4692 (class 0 OID 0)
-- Dependencies: 369
-- Name: TABLE larcauth_student_has_termevents; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_student_has_termevents TO anon;
GRANT ALL ON TABLE public.larcauth_student_has_termevents TO authenticated;
GRANT ALL ON TABLE public.larcauth_student_has_termevents TO service_role;


--
-- TOC entry 4693 (class 0 OID 0)
-- Dependencies: 370
-- Name: TABLE larcauth_student_has_weekevents; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_student_has_weekevents TO anon;
GRANT ALL ON TABLE public.larcauth_student_has_weekevents TO authenticated;
GRANT ALL ON TABLE public.larcauth_student_has_weekevents TO service_role;


--
-- TOC entry 4694 (class 0 OID 0)
-- Dependencies: 371
-- Name: TABLE larcauth_subjectgroup; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_subjectgroup TO anon;
GRANT ALL ON TABLE public.larcauth_subjectgroup TO authenticated;
GRANT ALL ON TABLE public.larcauth_subjectgroup TO service_role;


--
-- TOC entry 4695 (class 0 OID 0)
-- Dependencies: 387
-- Name: TABLE larcauth_sync_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_sync_log TO anon;
GRANT ALL ON TABLE public.larcauth_sync_log TO authenticated;
GRANT ALL ON TABLE public.larcauth_sync_log TO service_role;


--
-- TOC entry 4697 (class 0 OID 0)
-- Dependencies: 386
-- Name: SEQUENCE larcauth_sync_log_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.larcauth_sync_log_id_seq TO anon;
GRANT ALL ON SEQUENCE public.larcauth_sync_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.larcauth_sync_log_id_seq TO service_role;


--
-- TOC entry 4698 (class 0 OID 0)
-- Dependencies: 372
-- Name: TABLE larcauth_teachadm; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_teachadm TO anon;
GRANT ALL ON TABLE public.larcauth_teachadm TO authenticated;
GRANT ALL ON TABLE public.larcauth_teachadm TO service_role;


--
-- TOC entry 4699 (class 0 OID 0)
-- Dependencies: 373
-- Name: TABLE larcauth_term; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_term TO anon;
GRANT ALL ON TABLE public.larcauth_term TO authenticated;
GRANT ALL ON TABLE public.larcauth_term TO service_role;


--
-- TOC entry 4700 (class 0 OID 0)
-- Dependencies: 374
-- Name: TABLE larcauth_termsubject_has_homework; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_termsubject_has_homework TO anon;
GRANT ALL ON TABLE public.larcauth_termsubject_has_homework TO authenticated;
GRANT ALL ON TABLE public.larcauth_termsubject_has_homework TO service_role;


--
-- TOC entry 4701 (class 0 OID 0)
-- Dependencies: 375
-- Name: TABLE larcauth_timeperiod; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_timeperiod TO anon;
GRANT ALL ON TABLE public.larcauth_timeperiod TO authenticated;
GRANT ALL ON TABLE public.larcauth_timeperiod TO service_role;


--
-- TOC entry 4702 (class 0 OID 0)
-- Dependencies: 376
-- Name: TABLE larcauth_type_event; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_type_event TO anon;
GRANT ALL ON TABLE public.larcauth_type_event TO authenticated;
GRANT ALL ON TABLE public.larcauth_type_event TO service_role;


--
-- TOC entry 4703 (class 0 OID 0)
-- Dependencies: 377
-- Name: TABLE larcauth_unit; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_unit TO anon;
GRANT ALL ON TABLE public.larcauth_unit TO authenticated;
GRANT ALL ON TABLE public.larcauth_unit TO service_role;


--
-- TOC entry 4704 (class 0 OID 0)
-- Dependencies: 378
-- Name: TABLE larcauth_unit_period; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.larcauth_unit_period TO anon;
GRANT ALL ON TABLE public.larcauth_unit_period TO authenticated;
GRANT ALL ON TABLE public.larcauth_unit_period TO service_role;


--
-- TOC entry 4714 (class 0 OID 0)
-- Dependencies: 390
-- Name: TABLE sync_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sync_log TO anon;
GRANT ALL ON TABLE public.sync_log TO authenticated;
GRANT ALL ON TABLE public.sync_log TO service_role;


--
-- TOC entry 4716 (class 0 OID 0)
-- Dependencies: 389
-- Name: SEQUENCE sync_log_seq_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.sync_log_seq_seq TO anon;
GRANT ALL ON SEQUENCE public.sync_log_seq_seq TO authenticated;
GRANT ALL ON SEQUENCE public.sync_log_seq_seq TO service_role;


--
-- TOC entry 4717 (class 0 OID 0)
-- Dependencies: 388
-- Name: TABLE sync_state; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sync_state TO anon;
GRANT ALL ON TABLE public.sync_state TO authenticated;
GRANT ALL ON TABLE public.sync_state TO service_role;


--
-- TOC entry 4722 (class 0 OID 0)
-- Dependencies: 391
-- Name: TABLE sync_table_config; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.sync_table_config TO anon;
GRANT ALL ON TABLE public.sync_table_config TO authenticated;
GRANT ALL ON TABLE public.sync_table_config TO service_role;


--
-- TOC entry 2596 (class 826 OID 16494)
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- TOC entry 2597 (class 826 OID 16495)
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- TOC entry 2595 (class 826 OID 16493)
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- TOC entry 2599 (class 826 OID 16497)
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- TOC entry 2594 (class 826 OID 16492)
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- TOC entry 2598 (class 826 OID 16496)
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


-- Completed on 2026-05-05 12:22:22

--
-- PostgreSQL database dump complete
--

\unrestrict TiEVmZXggUzogKp4cje0Z8w6FzXbfXUL3kxLpuQkc97dbvjPmdcpUXiUokBUBS2

