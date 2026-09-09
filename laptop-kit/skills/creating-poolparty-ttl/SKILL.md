---
name: creating-poolparty-ttl
description: Use when creating or fixing taxonomy/ontology Turtle (TTL/RDF) files for import into Graphwise or PoolParty — including when an import fails, silently drops classes/relations, or when asked for a "PoolParty-compatible" SKOS thesaurus or custom ontology.
---

# Creating PoolParty-Compatible TTL

## Overview

Valid SKOS/OWL is NOT enough. PoolParty (now Graphwise) requires proprietary `ppt:` (`http://schema.semantic-web.at/ppt/`) wiring that no amount of standards-correct RDF replaces. Files without it fail to import or import empty.

**Core principle: three files, everything registered twice.** Every class, attribute, and relation must be (1) declared, (2) enumerated in the ontology header, and (3) registered in the project container. Anything not enumerated does not exist to PoolParty.

## The Three-File Pattern

| File | Role | Must contain |
|------|------|-------------|
| `schema.ttl` | Project container | `a rdfs:Container` with `ppt:linksToClass`, `ppt:linksToAttributeProperty`, `ppt:linksToPropertyWithInverse`, `ppt:linksToDirectedProperty`, `ppt:BaseUrl`, `ppt:identifier`, `ppt:hasLanguagePreference` |
| `ontology.ttl` | Custom ontology | `owl:Ontology` header with `ppt:BaseUrl`, `ppt:identifier`, `ppt:visible "PUBLIC"`, `ppt:hasLanguagePreference`, and full enumerations via `ppt:containsCustomType` / `ppt:containsAttributeProperty` / `ppt:containsPropertyWithInverse` |
| `taxonomy.ttl` | SKOS thesauri | Schemes with `rdfs:label` + `dct:title` + `dct:description` + `ppt:appliedType`; concepts dual-typed |

Copy the templates in [poolparty-pattern.md](poolparty-pattern.md) — do not write from memory.

## Hard Rules

1. **Every object property has a named inverse**, declared in BOTH directions with `owl:inverseOf` (`AMENDS`/`AMENDED_BY`). No `rdfs:subPropertyOf` hierarchies.
2. **Taxonomy tagging goes through ONE directed property** (conventionally `hasConcept`, range `skos:Concept`, no inverse, registered via `ppt:linksToDirectedProperty`) — never ad-hoc object properties with range `skos:Concept`.
3. **Concepts are dual-typed**: `a skos:Concept, onto:ConceptAreaClass`. Create one "concept-area" `owl:Class` per taxonomy facet; bridge top concept ↔ class with `skos:exactMatch` both ways.
4. **No named-class subclassing** (`rdfs:subClassOf <NamedClass>`). Express kind/role via `hasConcept` tags. Only `rdfs:subClassOf [ a owl:Restriction ; ... ]` cardinality restrictions are safe.
5. **Everything gets `rdfs:label "..."@en`** — classes, properties, attributes. All literals language-tagged.
6. **Datatypes**: dates as `xsd:string`, numbers `xsd:integer`/`xsd:decimal`, URLs `xsd:anyURI`. No `xsd:gYear`, no `owl:unionOf` blank nodes in domain/range (multiple named classes as repeated domain/range values are fine).
7. **Concepts**: every one needs `skos:inScheme`, `skos:prefLabel@en`, `skos:definition@en`, and `skos:broader` or `skos:topConceptOf` (no orphans). `skos:hasTopConcept`/`skos:topConceptOf` declared as a pair.
8. **Ontology namespace ends in `#`; taxonomy namespace ends in `/`.** Standard generic namespaces: `@prefix onto: <https://vocab.graphwise-demo.com/kg/ontology#>` and `@prefix taxo: <https://vocab.graphwise-demo.com/taxonomy/>` — use these unless the project dictates its own domain. `ppt:identifier` in schema.ttl must match the PoolParty project identifier; `ppt:BaseUrl` must match the target server.

## Validate Before Declaring Done

```bash
python validate_poolparty_ttl.py --ontology ontology.ttl --taxonomy taxonomy.ttl --schema schema.ttl
```

Run [validate_poolparty_ttl.py](validate_poolparty_ttl.py) (needs `rdflib`). It checks inverse symmetry, header/container enumerations vs declarations, dual-typing, orphans, and exactMatch bridges. Do not hand off files that fail it.

## Common Mistakes

| Mistake | Consequence |
|---------|-------------|
| "Clean standards-only SKOS/OWL is safest" | The #1 failure. PoolParty needs `ppt:` wiring; without it nothing imports |
| Declaring a property but omitting it from header/container enumerations | Silently absent from the project |
| One-directional `owl:inverseOf` | Broken relation pair in PoolParty UI |
| Ad-hoc `documentType`-style properties with range `skos:Concept` | Not importable as relations; use `hasConcept` |
| Untagged literals | Land in a "no language" bucket |
| `owl:imports`, individuals, unionOf constructs | Importer ignores or chokes |

## Known-Good Reference

Working example (verified imports): `/Users/kstroker/Desktop/myWork/code/demo/VA Benefits/modeling/` — compare against it when in doubt.
