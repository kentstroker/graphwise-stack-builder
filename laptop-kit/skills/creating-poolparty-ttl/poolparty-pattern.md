# PoolParty Three-File Pattern — Templates

Standard generic namespaces: `onto:` = `https://vocab.graphwise-demo.com/kg/ontology#` and `taxo:` = `https://vocab.graphwise-demo.com/taxonomy/` — use these as-is for demo projects; only substitute a different domain if the project dictates one. Replace `PROJECT-ID` throughout. Ontology namespace ends `#`, taxonomy ends `/`.

## Identifiers and Placeholders

- **Two different `ppt:identifier`s.** The one in `schema.ttl` MUST equal the PoolParty project identifier chosen when the project is created. The one in the ontology header is a separate ontology-level name (stable CamelCase). For generic demo stacks both are FIXED: project identifier `knowledge-graph`, ontology identifier `KnowledgeGraph` — create every PoolParty project with exactly the identifier `knowledge-graph`.
- **Placeholder domains are fine while authoring.** If no real PoolParty server is known, use the demo/vocab domain as `ppt:BaseUrl` and note that it must be edited to the actual server URL before import.
- **`dcterms:creator <http://localhost/user/superadmin>`** is inert provenance metadata; the superadmin default works — no need to match a real user.
- **`ppt:appliedType`**: exactly one value per scheme; multiple schemes may share the same applied type.
- **Top concepts**: a scheme may have one OR several top concepts (the VA reference has schemes with four). Rule of thumb: one concept-area class per top concept; concepts under it dual-type with that class.

## Core Vocabulary (REQUIRED, verbatim)

Every ontology MUST declare these pipeline-facing terms with these exact local
names — the n8n ingest workflows hardcode them:

`onto:Chunk` (owl:Class), `onto:hasChunk`/`onto:fromDocument` (inverse pair,
document class ↔ Chunk), `onto:chunkSequence` (xsd:integer),
`onto:chunkText` (xsd:string), `onto:vectorId` (xsd:string), and
`onto:hasConcept` (the directed tagging property, range skos:Concept).
Domain relations may use any naming style; these seven names never change.
The GraphDB repository is always named `knowledge-graph`.
Verify with `validate_poolparty_ttl.py ... --require-contract`.

## 1. schema.ttl — Project Container

```turtle
@prefix onto:     <https://vocab.graphwise-demo.com/kg/ontology#> .
@prefix dcterms: <http://purl.org/dc/terms/> .
@prefix ppt:     <http://schema.semantic-web.at/ppt/> .
@prefix rdfs:    <http://www.w3.org/2000/01/rdf-schema#> .
@prefix xsd:     <http://www.w3.org/2001/XMLSchema#> .

# ppt:BaseUrl must match the PoolParty server; ppt:identifier must match
# the project identifier used when creating the project in PoolParty.
<https://vocab.graphwise-demo.com/PROJECT-ID> a rdfs:Container ;
    rdfs:label "Project Display Name"@en ;
    dcterms:created "2026-01-01T00:00:00+00:00"^^xsd:dateTime ;
    dcterms:creator <http://localhost/user/superadmin> ;
    ppt:BaseUrl "https://vocab.graphwise-demo.com" ;
    ppt:ResourceSeparator "/" ;
    ppt:identifier "PROJECT-ID" ;
    ppt:visible "PUBLIC" ;
    ppt:hasLanguagePreference <urn:PROJECT-ID-lang-en-schema> ;
    ppt:linksToClass onto:ClassA , onto:ClassB ;                        # EVERY owl:Class
    ppt:linksToAttributeProperty onto:attrOne , onto:attrTwo ;          # EVERY owl:DatatypeProperty
    ppt:linksToPropertyWithInverse onto:REL_ONE , onto:REL_ONE_INV ;    # EVERY object property AND its inverse
    ppt:linksToDirectedProperty onto:hasConcept .                     # the taxonomy-tagging property

<urn:PROJECT-ID-lang-en-schema> a ppt:LanguagePreference ;
    ppt:languagePreferencePriority "0"^^xsd:int ;
    ppt:languagePreferenceValue "en" .
```

## 2. ontology.ttl — Custom Ontology

```turtle
@prefix onto:  <https://vocab.graphwise-demo.com/kg/ontology#> .
@prefix taxo:  <https://vocab.graphwise-demo.com/taxonomy/> .
@prefix dct:  <http://purl.org/dc/terms/> .
@prefix owl:  <http://www.w3.org/2002/07/owl#> .
@prefix ppt:  <http://schema.semantic-web.at/ppt/> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix skos: <http://www.w3.org/2004/02/skos/core#> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .

<https://vocab.graphwise-demo.com/kg/ontology> a owl:Ontology ;
    rdfs:label "Domain Knowledge Graph Ontology"@en ;
    dct:title "Domain Knowledge Graph Ontology"@en ;
    dct:description "..."@en ;
    dct:created "2026-01-01"^^xsd:date ;
    ppt:BaseUrl "https://vocab.graphwise-demo.com/kg" ;
    ppt:ResourceSeparator "/" ;
    ppt:identifier "DomainKG" ;
    ppt:visible "PUBLIC" ;
    ppt:hasLanguagePreference <urn:PROJECT-ID-lang-en> ;
    owl:versionInfo "0.1.0" ;
    ppt:containsCustomType onto:ClassA , onto:ClassB ;                  # EVERY owl:Class (concept-area + entity)
    ppt:containsAttributeProperty onto:attrOne , onto:attrTwo ;         # EVERY owl:DatatypeProperty
    ppt:containsPropertyWithInverse onto:REL_ONE , onto:REL_ONE_INV .   # EVERY object property + inverse
    # NOTE: hasConcept is NOT listed here — only in schema.ttl (linksToDirectedProperty)

<urn:PROJECT-ID-lang-en> a ppt:LanguagePreference ;
    ppt:languagePreferencePriority "0"^^xsd:int ;
    ppt:languagePreferenceValue "en" .

# --- Concept-area class: ONE per taxonomy facet; taxonomy concepts dual-type with it ---
onto:ClassA a owl:Class ;
    rdfs:label "Class A"@en ;
    rdfs:comment "..."@en ;
    skos:altLabel "Synonym"@en ;
    skos:exactMatch taxo:ClassA .          # bridge to the facet's top concept

# --- Entity class with optional cardinality restriction (the ONLY safe subClassOf form) ---
onto:ClassB a owl:Class ;
    rdfs:label "Class B"@en ;
    rdfs:comment "..."@en ;
    rdfs:subClassOf [ a owl:Restriction ;
            owl:onClass onto:ClassA ;
            owl:onProperty onto:REL_ONE ;
            owl:minQualifiedCardinality "1"^^xsd:nonNegativeInteger ] .

# --- The single taxonomy-tagging property (directed: no inverse, range skos:Concept) ---
onto:hasConcept a owl:ObjectProperty ;
    rdfs:label "Has Concept"@en ;
    dct:source "PoolParty annotation" ;
    rdfs:range skos:Concept ;
    rdfs:comment "Links a knowledge graph entity to a SKOS taxonomy concept that categorizes it."@en .

# --- Object properties: ALWAYS a named pair, owl:inverseOf declared BOTH directions ---
onto:REL_ONE a owl:ObjectProperty ;
    rdfs:label "Rel One"@en ;
    rdfs:comment "..."@en ;
    rdfs:domain onto:ClassB ;              # multiple named classes allowed (repeat, no unionOf)
    rdfs:range onto:ClassA ;
    owl:inverseOf onto:REL_ONE_INV .

onto:REL_ONE_INV a owl:ObjectProperty ;
    rdfs:label "Rel One Inv"@en ;
    rdfs:domain onto:ClassA ;
    rdfs:range onto:ClassB ;
    owl:inverseOf onto:REL_ONE .

# --- Datatype properties: dates as xsd:string; string/integer/decimal/anyURI only ---
onto:attrOne a owl:DatatypeProperty ;
    rdfs:label "Attr One"@en ;
    rdfs:comment "..."@en ;
    rdfs:domain onto:ClassB ;
    rdfs:range xsd:string ;
    skos:altLabel "Synonym"@en .

onto:attrTwo a owl:DatatypeProperty ;
    rdfs:label "Attr Two"@en ;
    rdfs:domain onto:ClassB ;
    rdfs:range xsd:integer .
```

## 3. taxonomy.ttl — SKOS Thesauri

```turtle
@prefix onto:  <https://vocab.graphwise-demo.com/kg/ontology#> .
@prefix taxo:  <https://vocab.graphwise-demo.com/taxonomy/> .
@prefix skos: <http://www.w3.org/2004/02/skos/core#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix owl:  <http://www.w3.org/2002/07/owl#> .
@prefix dct:  <http://purl.org/dc/terms/> .
@prefix ppt:  <http://schema.semantic-web.at/ppt/> .
@prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .

# One scheme per facet. Scheme needs rdfs:label AND dct:title AND dct:description.
# ppt:appliedType = the entity class whose instances get tagged with this scheme's concepts.
taxo:ClassAScheme a skos:ConceptScheme ;
    rdfs:label "Class A Facet"@en ;
    dct:title "Class A Facet"@en ;
    dct:description "..."@en ;
    ppt:appliedType onto:ClassB ;
    skos:hasTopConcept taxo:ClassA .

# Top concept: dual-typed with its concept-area class, self-bridged with exactMatch.
taxo:ClassA a skos:Concept, onto:ClassA ;
    skos:inScheme taxo:ClassAScheme ;
    skos:topConceptOf taxo:ClassAScheme ;      # pairs with hasTopConcept above
    skos:prefLabel "Class A"@en ;
    skos:definition "..."@en ;
    skos:exactMatch onto:ClassA ;
    skos:narrower taxo:ChildConcept .

# Every narrower concept: dual-typed with the facet's class, inScheme, broader, prefLabel, definition.
taxo:ChildConcept a skos:Concept, onto:ClassA ;
    skos:inScheme taxo:ClassAScheme ;
    skos:broader taxo:ClassA ;
    skos:prefLabel "Child Concept"@en ;
    skos:altLabel "Synonym"@en ;
    skos:definition "..."@en .
```

## Checklist Ordering That Prevents Rework

1. List taxonomy facets → create one concept-area class each.
2. List entity classes, then relations as inverse PAIRS, then attributes.
3. Write ontology bodies, THEN fill the three header enumerations from what you declared.
4. Write taxonomy with dual-typing against the declared classes.
5. Write schema.ttl by copying the ontology header enumerations (+ hasConcept as directed).
6. Run the validator.
