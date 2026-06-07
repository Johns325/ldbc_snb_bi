// Q19. Interaction path between cities
// Requires the Neo4j Graph Data Science library
/*
:params { city1Id: 669, city2Id: 648 }
*/
MATCH
  (person1:Person)-[:IS_LOCATED_IN]->(:City {id: $city1Id}),
  (person2:Person)-[:IS_LOCATED_IN]->(:City {id: $city2Id})
WITH collect({source: person1, target: person2}) AS pairs
CALL gds.graph.drop('bi19_without_precomputation', false)
YIELD graphName

// ----------------------------------------------------------------------------------------------------
WITH pairs, count(*) AS dummy
// ----------------------------------------------------------------------------------------------------

CALL gds.graph.project.cypher(
  'bi19_without_precomputation',
  'MATCH (p:Person) RETURN id(p) AS id',
  'MATCH
     (personA:Person)-[:KNOWS]-(personB:Person),
     (personA)<-[:HAS_CREATOR]-(:Message)-[replyOf:REPLY_OF]-(:Message)-[:HAS_CREATOR]->(personB)
   WITH
     id(personA) AS source,
     id(personB) AS target,
     count(replyOf) AS numInteractions
   RETURN
     source,
     target,
     CASE WHEN round(40-sqrt(numInteractions)) > 1 THEN round(40-sqrt(numInteractions)) ELSE 1 END AS weight'
)
YIELD graphName

// ----------------------------------------------------------------------------------------------------
WITH graphName, pairs
// ----------------------------------------------------------------------------------------------------

UNWIND pairs AS pair
WITH graphName, pair.source AS person1, pair.target AS person2
CALL gds.shortestPath.dijkstra.stream(graphName, {
  sourceNode: person1,
  targetNode: person2,
  relationshipWeightProperty: 'weight'
})
YIELD totalCost
WITH graphName, person1.id AS person1Id, person2.id AS person2Id, totalCost AS totalWeight
ORDER BY totalWeight ASC, person1Id ASC, person2Id ASC
WITH graphName, collect({person1Id: person1Id, person2Id: person2Id, totalWeight: totalWeight}) AS results
CALL gds.graph.drop(graphName, false)
YIELD graphName AS droppedGraphName
WITH results
UNWIND results AS result
WITH result.person1Id AS person1Id, result.person2Id AS person2Id, result.totalWeight AS totalWeight, results
WHERE totalWeight = results[0].totalWeight
RETURN person1Id, person2Id, totalWeight
ORDER BY person1Id, person2Id
