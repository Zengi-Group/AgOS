# AGOS — Complete Architecture Package

**Status:** Ready for Vibecoding Sprints (with 1 Critical Gap)  
**Date:** March 17, 2026  
**Date updated:** June 22, 2026

---

## 📦 What You Have

### Documentation (315K) — Read in This Order

1. **AGOS-Dok1-v1_9.md** (77K+, 1772+ lines)
   - Domain Model with 91 entities
   - Consolidated ERD (Mermaid)
   - Ownership Matrix (who reads/writes what)
   - FSM Catalog (all state machines)
   - **START HERE** — this is your data model truth source

2. **AGOS-Dok3-RPC-Catalog-v1_5.md** (43K, 814 lines)
   - All 67 callable functions
   - Parameter signatures
   - Return types
   - Implementation status (which ones are in SQL)

3. **AGOS-Dok4-EventBus-v1_1.md** (canon — `.docx` ретайрнут 2026-06-24)
   - 59 canonical events
   - When each fires (triggers)
   - Notification templates
   - Proactive engine subscriptions

4. **AGOS-Dok5-AIGateway-v1_7.md** (112K, 2315 lines)
   - LangGraph architecture
   - Two-run confirmation pattern (critical for WhatsApp)
   - Tool catalog (mapped to d07 SQL RPCs)
   - JWT claim structure
   - Concurrency model (SKIP LOCKED)

### SQL Schema (783K) — Execute in This Order

1. **d01_kernel.sql** (175K, 3343 lines)
   - Identity domain (User, Organization, Roles)
   - Farm domain (HerdGroup, HerdEvent)
   - Platform domain (PlatformEvent, Notification, AuditLog)
   - **Run this first.** Zero dependencies.

2. **d02_tsp.sql** (54K, 985 lines)
   - Market/Trading Coordination (Batch, Pool, Delivery)
   - Price grids and indices
   - Depends on: d01

3. **d03_feed.sql** (52K, 892 lines)
   - Feed inventory, nutrition planning
   - Rations and feeding schedules
   - Depends on: d01

4. **d04_vet.sql** (109K, 1698 lines)
   - Veterinary cases, diagnoses, treatments
   - Vaccination protocols and plans
   - Epidemic thresholds (reference data)
   - Depends on: d01

5. **d05_ops_edu.sql** (232K, 4275 lines)
   - Production cycle templates and farm plans
   - Task management
   - Education platform (courses, modules, enrollments)
   - KPI tracking
   - Depends on: d01

6. **d07_ai_gateway.sql** (135K, 2977 lines)
   - All RPC implementations for LangGraph tools
   - JWT validation, org ownership checks
   - Farm context extraction
   - Depends on: d01-d05

7. **d08_epidemic.sql** (26K, 543 lines)
   - Epidemic detection triggers
   - Threshold checking and signal generation
   - Depends on: d01, d04

8. **d09_consulting.sql**
   - Consulting/NASEM tables and RPC
   - Feeding model, ration calculation, consulting projects
   - Depends on: d01, d03, d05

9. **d10_public_site.sql**
   - 18 tables: finance, subsidy, startup, news, registration
   - Public-facing site content and registration flows
   - Depends on: d01

10. **d11_norms.sql**
    - farm_norms_ref reference data
    - Normative references for farm operations
    - Depends on: d01

---

## 🎯 What's Next

### For Vibecoding Sprints

1. **Start DB-1 KERNEL** (d01_kernel.sql)
   - Run SQL in clean Supabase project
   - Verify RLS policies auto-enforced
   - Test FK dependencies

2. **Then Sequential:**
   - DB-2 (d02_tsp) → DB-3 (d03_feed) → DB-4 (d04_vet) → DB-5 (d05_ops_edu)
   - DB-7 (d07_ai_gateway) → DB-8 (d08_epidemic)
   - DB-9 (d09_consulting) → DB-10 (d10_public_site) → DB-11 (d11_norms)
   - Each depends on prior ones — **do not parallelize yet**

3. **AI Gateway (Python)**
   - Use d07_ai_gateway.sql RPC definitions
   - Implement LangGraph per Dok 5 specification
   - Map each tool to RPC via rpc_* naming convention (see Dok 5 §2)

4. **Web Cabinet (Vite + React + TypeScript)**
   - Dok 6 is maintained as slice files — see section below
   - Match screen definitions to entities in Dok 1
   - Use design system: warm palette (`:root`) for farmer cabinet; neutral (`.light`) for expert console

---

## Dok 6 — Interface Contracts (maintained as slice files)

Dok 6 is authored and maintained as individual slice files (no single consolidated master):

- Slice1-SickCalf, Slice2-Membership, Slice3-Feed, Slice4-Operations
- Slice5a-Market-Farmer, Slice5b-Market-Admin, Slice6a-Expert, Slice6b-Admin
- Slice-CAPEX, A-CAT-AdminScreens-v1_0
- (Education slice F24-F28/A16-A19: NOT YET authored — see IMPL_DEBT / EDUCATION-01)

There is no consolidated Dok6 master file; slices are canonical.

---

## 🔗 Cross-Document References

**If you need to understand...** | **Read this first...**
---|---
How farmer data flows through the system | Dok 1 (§2 Domain Map + §3 ERD)
What data each module reads/writes | Dok 1 (§4 Ownership Matrix)
How to call business logic from Web/AI | Dok 3 (RPC signatures)
How modules communicate | Dok 4 (Event Bus subscriptions)
How AI agents interact with the platform | Dok 5 (Tool catalog + two-run pattern)
Individual entity design | d01-d11 (search CREATE TABLE)
RPC implementations | d01-d11 (search CREATE OR REPLACE FUNCTION)

---

## ✅ Verification

All files have been verified as of **March 17, 2026, 15:06 UTC+6**:

- ✅ Dok 1-5 latest versions from /mnt/project
- ✅ SQL d01-d05, d07-d08 consolidated and deduplicated
- ✅ No CRITICAL errors in cross-check validation
- ✅ RLS policies auto-enforced on all tables
- ✅ Dok 6 maintained as slice files (see Dok 6 section above)
- ✅ SQL domain files: d01–d11, 10 files total (no d06 — logical domains consolidated)

---

## 📞 Questions?

**For architecture/schema questions:** Reference Dok 1 + relevant SQL file  
**For RPC questions:** Reference Dok 3 + d07_ai_gateway.sql  
**For event flow questions:** Reference Dok 4  
**For AI implementation:** Reference Dok 5 + d07_ai_gateway.sql  
**For UI/screen questions:** Reference Dok 6 slice files (see Dok 6 section above)

---

**Prepared by:** Claude, CTO  
**For:** Arshidin, CEO TURAN  
**Project:** TURAN Agricultural Operating System (AgOS)
