-- Function: xt.workflow_inheritsource(text, text, uuid, integer, integer)

-- DROP FUNCTION xt.workflow_inheritsource(text, text, uuid, integer, integer);

CREATE OR REPLACE FUNCTION xt.workflow_inheritsource(
    source_model text,
    workflow_class text,
    item_uuid uuid,
    parent_id integer,
    order_id integer)
  RETURNS text AS
$BODY$
  if (!parent_id)
    return '';

  var DEBUG = true;
  
  var orm,
    namespace,
    modeltype,
    sourceTable,
    workflowTable,
    wfsource,
    wfmodel,
    templateExistsSql,
    templateSQL,
    insertSQL,
    updateCompletedSQL,
    updateDeferredSQL,
    templateItems = [],
    options = { superUser: true },
    i = 0;

  namespace = source_model.split(".")[0];
  modeltype = source_model.split(".")[1];
  /* Check the first param to see if it's a 'workflow source table' */
  wfsource = plv8.execute("select true as wfsrc from xt.wftype where wftype_src_tblname = $1; ",
    [modeltype])[0].wfsrc == true ? true : false;
  if (wfsource) {
    sourceTable = source_model; /*i.e. xt.saletypewf */
  } else {
    wfsource = XT.Data.fetchOrm(namespace, modeltype, options).properties.filter(function (wf) {
      return wf.name === "workflow";  })[0].toMany.type;
    sourceTable = XT.Orm.fetch(namespace, wfsource, options).table; /* i.e. xt.coheadwf */
  }

  namespace = workflow_class.split(".")[0];
  modeltype = workflow_class.split(".")[1];

  workflowTable = XT.Orm.fetch(namespace, modeltype, options).table;

  if (!sourceTable || !workflowTable || !item_uuid) {
    plv8.elog(ERROR,"Missing parameters supplied or invalid source/target models supplied. " + 
    " Values are: sourceTable = " + sourceTable +
    ", workflowTable = " + workflowTable +
    ", item_uuid = " + item_uuid + 
    ", parent_id = " + parent_id);
  }

  templateExistsSql = "SELECT count(*) as count FROM %1$I.%2$I WHERE wf_parent_uuid = $1";
  templateSQL = "SELECT obj_uuid, wfsrc_id, wfsrc_name as name,wfsrc_description as descr,wfsrc_type as type,wfsrc_status as status, " +
    "CASE WHEN wfsrc_start_set THEN current_date + wfsrc_start_offset ELSE null END as startDate, " +
    "CASE WHEN wfsrc_due_set THEN current_date + wfsrc_due_offset ELSE null END as dueDate, " +
    "wfsrc_notes as notes, wfsrc_priority_id as priority,wfsrc_owner_username as owner,wfsrc_assigned_username as assigned, " +
    "wfsrc_completed_parent_status as compl_status,wfsrc_deferred_parent_status as defer_status,wfsrc_sequence as sequence, " +
    "wfsrc_completed_successors as compl_successor, wfsrc_deferred_successors as defer_successor" +
    " FROM %1$I.%2$I WHERE wfsrc_parent_id = $1 ";
  insertSQL = "INSERT INTO %1$I.%2$I (wf_name, wf_description, wf_type, wf_status,wf_start_date,wf_due_date,wf_notes, " +
    "wf_priority_id,wf_owner_username,wf_assigned_username,wf_parent_uuid,wf_completed_parent_status,wf_deferred_parent_status, " +
    "wf_sequence, wf_completed_successors, wf_deferred_successors) " +
    "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16) " +
    " RETURNING obj_uuid";
  updateCompletedSQL = "UPDATE %1$I.%2$I SET wf_completed_successors=$1 " +
      "WHERE wf_completed_successors = $2 AND wf_parent_uuid = $3";
  updateDeferredSQL = "UPDATE %1$I.%2$I SET wf_deferred_successors=$1 " +
      "WHERE wf_deferred_successors = $2 AND wf_parent_uuid = $3";   
      
  /* PRINTER HANDLING -- added March 2016 */
  var insertPpSQL = "INSERT INTO workflow.wf_printparam ( "
     + "   wf_printparam_order, wf_printparam_name, "
     + "   wf_printparam_value, wf_printparam_type, "
     + "   wf_printparam_parent_uuid ) "
     + " ( SELECT "                      
     + "   wfsrc_printparam_order, wfsrc_printparam_name, "
     + "   wfsrc_printparam_value, wfsrc_printparam_type, "
     + "   $1 AS parent_uuid " /* xt.wf.obj_uuid */ 
     + "   FROM workflow.wfsrc_printparam WHERE wfsrc_printparam_wfsrc_uuid = $2)";       
  var updateHeadIdPpSQL = "UPDATE workflow.wf_printparam SET wf_printparam_value = $1 "
     + " WHERE wf_printparam_name IN ('sohead_id','head_id','orderhead_id') " 
     + "   AND wf_printparam_parent_uuid = $2 ";
  var updateHeadTypePpSQL = "UPDATE workflow.wf_printparam SET wf_printparam_value = $1 " 
     + " WHERE wf_printparam_name IN ('head_type','orderhead_type') "
     + "   AND wf_printparam_parent_uuid = $2 ";
     
  /* find report -- added June 15 2016*/
  var report_name = 'placeholder_report';

  if (workflow_class == 'XM.SalesOrderWorkflow') {
    var report_name = 'coheadwf_report';
    var getreportSQL = "SELECT findcustomerform( "
     + " (SELECT cohead_cust_id FROM cohead WHERE cohead_id = $1), 'P') AS report_name"
    var getreport = plv8.execute(getreportSQL, [order_id]); 
    if (getreport.length > 0 )
    {
      report_name = getreport[0].report_name;       
      plv8.elog(WARNING, "cust report found: " + report_name);
    }
  }
  if (workflow_class == 'XM.PurchaseOrderWorkflow') {
    report_name = 'ReceivingLabel';
  }
  var updateHeadReportNameSQL = "UPDATE workflow.wf_printparam SET wf_printparam_value = $1 "
     + " WHERE wf_printparam_name = 'name' "
     + "   AND wf_printparam_parent_uuid = $2 ";

  var templateExistsSqlf = XT.format(templateExistsSql, [workflowTable.split(".")[0], workflowTable.split(".")[1]]);
  var templateWfExists = plv8.execute(templateExistsSqlf, [item_uuid])[0].count;

  if (templateWfExists > 0) {
    return '';
  }

/* Retrieve source workflow information */
  var templateWfsql = XT.format(templateSQL, [sourceTable.split(".")[0], sourceTable.split(".")[1]]);
  var templateWf = plv8.execute(templateWfsql, [parent_id]);

/* Create target workflow items and retain relationship between source and target uuid */
  templateWf.map(function (items) {
    templateItems[i] = [];
    templateItems[i]["sourceUuid"] = items.obj_uuid;

    var insertWfsql = XT.format(insertSQL, [workflowTable.split(".")[0], workflowTable.split(".")[1]]);
    var workflowWf = plv8.execute(insertWfsql, [items.name, items.descr, items.type, items.status, items.startDate, items.dueDate, items.notes,
      items.priority, items.owner, items.assigned, item_uuid, items.compl_status, items.defer_status, items.sequence, items.compl_successor, items.defer_successor]);
    templateItems[i]["newUuid"] = workflowWf[0].obj_uuid;
    
    /* Copy from wfsrc_printparam to wf_printparam */
    plv8.execute(insertPpSQL, [workflowWf[0].obj_uuid, items.obj_uuid]); 
    
    i++;
  });

  /* Reiterate through new workflow items and fix successor mappings */
  templateItems.map(function (items) {
    var completedSQL,
      deferredSQL,
      updateWf;

    /* Update Completed successors */
    completedSQL = XT.format(updateCompletedSQL, [workflowTable.split(".")[0], workflowTable.split(".")[1]]);
    updateWf = plv8.execute(completedSQL, [items["newUuid"],items["sourceUuid"],item_uuid]);
    /* Update Deferred successors */
    deferredSQL = XT.format(updateDeferredSQL, [workflowTable.split(".")[0], workflowTable.split(".")[1]]);
    updateWf = plv8.execute(deferredSQL, [items["newUuid"],items["sourceUuid"],item_uuid]);

    /* Update wf_printparam */
    var order_type = '';
    if (source_model == 'xt.saletypewf')     { order_type = 'SO'; }
    if (source_model == 'xt.potypewf')       { order_type = 'PO'; }
    if (source_model == 'xt.sitetypewf')     { order_type = 'TO'; }
    if (source_model == 'xt.plancodewf')     { order_type = 'WO'; }
    if (source_model == 'xt.prjtypewf')      { order_type = 'PRJ'; }      
    plv8.execute(updateHeadIdPpSQL, [order_id, items["newUuid"]]);    
    plv8.execute(updateHeadTypePpSQL, [order_type, items["newUuid"]]);
    plv8.execute(updateHeadReportNameSQL, [report_name, items["newUuid"]]);  
  });

  return item_uuid;

$BODY$
  LANGUAGE plv8 VOLATILE
  COST 100;
ALTER FUNCTION xt.workflow_inheritsource(text, text, uuid, integer, integer)
  OWNER TO admin;
