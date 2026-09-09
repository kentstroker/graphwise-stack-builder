#!/usr/bin/env python3
"""Validate taxonomy/ontology/schema Turtle files for PoolParty (Graphwise) import.

Usage:
    python validate_graph-modeling_ttl.py --ontology ontology.ttl [--taxonomy taxonomy.ttl] [--schema schema.ttl]

Requires: rdflib (pip install rdflib)

Checks the proprietary ppt: wiring PoolParty needs on top of valid RDF:
header metadata, enumeration completeness, inverse-pair symmetry, dual-typed
concepts, scheme metadata, hierarchy integrity, and exactMatch bridges.
Exit code 0 = all checks passed.
"""
import argparse
import sys

from rdflib import Graph, Namespace, RDF, URIRef
from rdflib.namespace import SKOS, OWL, RDFS, DCTERMS

PPT = Namespace("http://schema.semantic-web.at/ppt/")

ALLOWED_DATATYPES = {
    "http://www.w3.org/2001/XMLSchema#string",
    "http://www.w3.org/2001/XMLSchema#integer",
    "http://www.w3.org/2001/XMLSchema#int",
    "http://www.w3.org/2001/XMLSchema#decimal",
    "http://www.w3.org/2001/XMLSchema#float",
    "http://www.w3.org/2001/XMLSchema#boolean",
    "http://www.w3.org/2001/XMLSchema#date",
    "http://www.w3.org/2001/XMLSchema#dateTime",
    "http://www.w3.org/2001/XMLSchema#anyURI",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ontology", required=True)
    ap.add_argument("--taxonomy")
    ap.add_argument("--schema")
    ap.add_argument("--require-contract", action="store_true",
                    help="enforce the permanent graphwise-demo namespace contract")
    args = ap.parse_args()

    errors, warnings = [], []

    onto = Graph().parse(args.ontology, format="turtle")

    # --- Ontology header ---
    onto_nodes = list(onto.subjects(RDF.type, OWL.Ontology))
    if len(onto_nodes) != 1:
        errors.append(f"expected exactly 1 owl:Ontology node, found {len(onto_nodes)}")
        onto_node = onto_nodes[0] if onto_nodes else None
    else:
        onto_node = onto_nodes[0]

    classes = {s for s in onto.subjects(RDF.type, OWL.Class) if isinstance(s, URIRef)}
    attrs = set(onto.subjects(RDF.type, OWL.DatatypeProperty))
    objprops = set(onto.subjects(RDF.type, OWL.ObjectProperty))
    # Directed (taxonomy-tagging) properties: range skos:Concept, no inverse expected
    directed = {p for p in objprops if (p, RDFS.range, SKOS.Concept) in onto}
    paired = objprops - directed

    if not directed:
        warnings.append("no directed taxonomy-tagging property (object property with range skos:Concept, e.g. hasConcept)")

    if args.require_contract:
        CONTRACT_ONTO = "https://vocab.graphwise-demo.com/kg/ontology#"
        CONTRACT_TAXO = "https://vocab.graphwise-demo.com/taxonomy/"
        CONTRACT_PROJECT_ID = "knowledge-graph"
        CORE = ["Chunk", "hasChunk", "fromDocument", "chunkSequence",
                "chunkText", "vectorId", "hasConcept"]
        declared = {str(s) for s in classes | attrs | objprops}
        for term in CORE:
            if CONTRACT_ONTO + term not in declared:
                errors.append(f"contract: missing core vocabulary term onto:{term}")
        if not any(str(c).startswith(CONTRACT_ONTO) for c in classes):
            errors.append(f"contract: no classes in the contract namespace {CONTRACT_ONTO}")

    if onto_node is not None:
        for req in (PPT.BaseUrl, PPT.identifier, PPT.visible, PPT.hasLanguagePreference,
                    PPT.ResourceSeparator, RDFS.label, DCTERMS.title):
            if onto.value(onto_node, req) is None:
                errors.append(f"ontology header missing {req}")
        lang = onto.value(onto_node, PPT.hasLanguagePreference)
        if lang is not None and (lang, RDF.type, PPT.LanguagePreference) not in onto:
            errors.append(f"language preference node {lang} not typed ppt:LanguagePreference")

        hdr_types = set(onto.objects(onto_node, PPT.containsCustomType))
        hdr_attrs = set(onto.objects(onto_node, PPT.containsAttributeProperty))
        hdr_props = set(onto.objects(onto_node, PPT.containsPropertyWithInverse))
        for label, hdr, decl in (("containsCustomType", hdr_types, classes),
                                 ("containsAttributeProperty", hdr_attrs, attrs),
                                 ("containsPropertyWithInverse", hdr_props, paired)):
            if hdr != decl:
                only_hdr = {str(x) for x in hdr - decl}
                only_decl = {str(x) for x in decl - hdr}
                errors.append(f"ppt:{label} mismatch — header-only: {only_hdr or '{}'} declared-only: {only_decl or '{}'}")

    # --- Inverse symmetry ---
    for p in paired:
        inv = onto.value(p, OWL.inverseOf)
        if inv is None:
            errors.append(f"object property missing owl:inverseOf: {p}")
        elif onto.value(inv, OWL.inverseOf) != p:
            errors.append(f"inverse not symmetric: {p} <-> {inv}")

    # --- Labels, subclassing, datatypes ---
    for s in classes | attrs | objprops:
        lbl = onto.value(s, RDFS.label)
        if lbl is None:
            errors.append(f"missing rdfs:label: {s}")
        elif getattr(lbl, "language", None) is None:
            errors.append(f"rdfs:label missing language tag: {s}")
    for s, o in onto.subject_objects(RDFS.subClassOf):
        if isinstance(o, URIRef):
            errors.append(f"named-class subclassing (use HAS_CONCEPT tagging or a restriction instead): {s} subClassOf {o}")
    for a in attrs:
        rng = onto.value(a, RDFS.range)
        if rng is not None and str(rng) not in ALLOWED_DATATYPES:
            errors.append(f"attribute range {rng} not in PoolParty-safe set: {a}")

    # --- Taxonomy ---
    concepts = set()
    if args.taxonomy:
        tax = Graph().parse(args.taxonomy, format="turtle")
        concepts = set(tax.subjects(RDF.type, SKOS.Concept))
        schemes = set(tax.subjects(RDF.type, SKOS.ConceptScheme))
        if args.require_contract:
            bad = [str(c) for c in concepts
                   if not str(c).startswith("https://vocab.graphwise-demo.com/taxonomy/")]
            for b in bad[:5]:
                errors.append(f"contract: concept outside taxonomy namespace: {b}")
        if not schemes:
            errors.append("taxonomy has no skos:ConceptScheme")
        for s in schemes:
            for req in (RDFS.label, DCTERMS.title, DCTERMS.description):
                if tax.value(s, req) is None:
                    errors.append(f"scheme missing {req}: {s}")
            at = tax.value(s, PPT.appliedType)
            if at is None:
                errors.append(f"scheme missing ppt:appliedType: {s}")
            elif at not in classes:
                errors.append(f"scheme ppt:appliedType not a declared ontology class: {s} -> {at}")
            for tc in tax.objects(s, SKOS.hasTopConcept):
                if tax.value(tc, SKOS.topConceptOf) != s:
                    errors.append(f"hasTopConcept/topConceptOf not paired: {s} {tc}")
        for c in concepts:
            ctypes = set(tax.objects(c, RDF.type)) - {SKOS.Concept}
            if not ctypes:
                errors.append(f"concept not dual-typed with an ontology class: {c}")
            for t in ctypes:
                if t not in classes:
                    errors.append(f"concept dual-type is not a declared ontology class: {c} -> {t}")
            for req in (SKOS.inScheme, SKOS.prefLabel, SKOS.definition):
                if tax.value(c, req) is None:
                    errors.append(f"concept missing {req}: {c}")
            pl = tax.value(c, SKOS.prefLabel)
            if pl is not None and getattr(pl, "language", None) is None:
                errors.append(f"prefLabel missing language tag: {c}")
            if tax.value(c, SKOS.broader) is None and tax.value(c, SKOS.topConceptOf) is None:
                errors.append(f"orphan concept (no broader, not a top concept): {c}")
        for _, o in list(tax.subject_objects(SKOS.broader)) + list(tax.subject_objects(SKOS.narrower)):
            if o not in concepts:
                errors.append(f"broader/narrower target is not a declared concept: {o}")
        for c, m in tax.subject_objects(SKOS.exactMatch):
            if m not in classes and m not in concepts:
                errors.append(f"taxonomy exactMatch target unresolved: {c} -> {m}")
        for c, m in onto.subject_objects(SKOS.exactMatch):
            if m not in concepts and m not in classes:
                errors.append(f"ontology exactMatch target unresolved: {c} -> {m}")

    # --- Schema container ---
    if args.schema:
        sch = Graph().parse(args.schema, format="turtle")
        containers = list(sch.subjects(RDF.type, RDFS.Container))
        if len(containers) != 1:
            errors.append(f"schema: expected exactly 1 rdfs:Container, found {len(containers)}")
        else:
            cont = containers[0]
            for req in (PPT.BaseUrl, PPT.identifier, PPT.visible, PPT.hasLanguagePreference, RDFS.label):
                if sch.value(cont, req) is None:
                    errors.append(f"schema container missing {req}")
            if args.require_contract:
                pid = sch.value(cont, PPT.identifier)
                if str(pid) != "knowledge-graph":
                    errors.append(f"contract: schema ppt:identifier must be 'knowledge-graph', got '{pid}'")
            for label, pred, decl in (("linksToClass", PPT.linksToClass, classes),
                                      ("linksToAttributeProperty", PPT.linksToAttributeProperty, attrs),
                                      ("linksToPropertyWithInverse", PPT.linksToPropertyWithInverse, paired),
                                      ("linksToDirectedProperty", PPT.linksToDirectedProperty, directed)):
                got = set(sch.objects(cont, pred))
                if got != decl:
                    only_sch = {str(x) for x in got - decl}
                    only_decl = {str(x) for x in decl - got}
                    errors.append(f"schema ppt:{label} mismatch — schema-only: {only_sch or '{}'} declared-only: {only_decl or '{}'}")

    print(f"classes={len(classes)} attributes={len(attrs)} relations={len(paired)} directed={len(directed)} concepts={len(concepts)}")
    for w in warnings:
        print(f"WARNING: {w}")
    if errors:
        print(f"\n{len(errors)} ERROR(S):")
        for e in errors:
            print(f" - {e}")
        sys.exit(1)
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
