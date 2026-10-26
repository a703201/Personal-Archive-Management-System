-- ============================================================
-- AMS · 003_seed_perms_roles.sql
-- 初始化内置权限点与内置角色（FR-ACL-001 / FR-ACL-003）
--
-- 本文件由 scripts/gen_seed_perms.py 从
-- packages/ams-security/src/authz/perm.cj 的 BuiltinPerms 生成 ——
-- 代码是唯一事实来源，请勿手工编辑本文件。
--
-- openGauss 5.0.0 兼容：不支持 ON CONFLICT，故用
-- INSERT ... SELECT ... WHERE NOT EXISTS 实现幂等。
-- ============================================================

-- 权限点
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900001, 'archive:read:own', 'archive:read:own', 'archive', 'read', 'own', FALSE, 'archive:read:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:read:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900002, 'archive:read:any', 'archive:read:any', 'archive', 'read', 'any', TRUE, 'archive:read:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:read:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900003, 'archive:write:own', 'archive:write:own', 'archive', 'write', 'own', FALSE, 'archive:write:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:write:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900004, 'archive:write:any', 'archive:write:any', 'archive', 'write', 'any', TRUE, 'archive:write:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:write:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900005, 'archive:delete:own', 'archive:delete:own', 'archive', 'delete', 'own', TRUE, 'archive:delete:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:delete:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900006, 'archive:delete:any', 'archive:delete:any', 'archive', 'delete', 'any', TRUE, 'archive:delete:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:delete:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900007, 'archive:export:own', 'archive:export:own', 'archive', 'export', 'own', TRUE, 'archive:export:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:export:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900008, 'archive:export:any', 'archive:export:any', 'archive', 'export', 'any', TRUE, 'archive:export:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:export:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900009, 'archive:read_sensitive', 'archive:read_sensitive', 'archive', 'read_sensitive', '', TRUE, 'archive:read_sensitive' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:read_sensitive');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900010, 'archive:manage', 'archive:manage', 'archive', 'manage', '', TRUE, 'archive:manage' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'archive:manage');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900011, 'subject:read:own', 'subject:read:own', 'subject', 'read', 'own', FALSE, 'subject:read:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'subject:read:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900012, 'subject:read:any', 'subject:read:any', 'subject', 'read', 'any', TRUE, 'subject:read:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'subject:read:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900013, 'subject:write:own', 'subject:write:own', 'subject', 'write', 'own', FALSE, 'subject:write:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'subject:write:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900014, 'subject:manage', 'subject:manage', 'subject', 'manage', '', TRUE, 'subject:manage' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'subject:manage');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900015, 'attachment:read:own', 'attachment:read:own', 'attachment', 'read', 'own', FALSE, 'attachment:read:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:read:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900016, 'attachment:read:any', 'attachment:read:any', 'attachment', 'read', 'any', TRUE, 'attachment:read:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:read:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900017, 'attachment:upload:own', 'attachment:upload:own', 'attachment', 'upload', 'own', FALSE, 'attachment:upload:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:upload:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900018, 'attachment:upload:any', 'attachment:upload:any', 'attachment', 'upload', 'any', TRUE, 'attachment:upload:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:upload:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900019, 'attachment:download:own', 'attachment:download:own', 'attachment', 'download', 'own', FALSE, 'attachment:download:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:download:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900020, 'attachment:download:any', 'attachment:download:any', 'attachment', 'download', 'any', TRUE, 'attachment:download:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:download:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900021, 'attachment:delete:own', 'attachment:delete:own', 'attachment', 'delete', 'own', TRUE, 'attachment:delete:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:delete:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900022, 'attachment:delete:any', 'attachment:delete:any', 'attachment', 'delete', 'any', TRUE, 'attachment:delete:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:delete:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900023, 'attachment:manage', 'attachment:manage', 'attachment', 'manage', '', TRUE, 'attachment:manage' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'attachment:manage');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900024, 'tag:read:own', 'tag:read:own', 'tag', 'read', 'own', FALSE, 'tag:read:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'tag:read:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900025, 'tag:write:own', 'tag:write:own', 'tag', 'write', 'own', FALSE, 'tag:write:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'tag:write:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900026, 'notify:read:own', 'notify:read:own', 'notify', 'read', 'own', FALSE, 'notify:read:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'notify:read:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900027, 'acl:read:own', 'acl:read:own', 'acl', 'read', 'own', FALSE, 'acl:read:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'acl:read:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900028, 'acl:grant:own', 'acl:grant:own', 'acl', 'grant', 'own', TRUE, 'acl:grant:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'acl:grant:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900029, 'acl:revoke:own', 'acl:revoke:own', 'acl', 'revoke', 'own', TRUE, 'acl:revoke:own' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'acl:revoke:own');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900030, 'acl:manage', 'acl:manage', 'acl', 'manage', '', TRUE, 'acl:manage' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'acl:manage');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900031, 'user:read:any', 'user:read:any', 'user', 'read', 'any', TRUE, 'user:read:any' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'user:read:any');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900032, 'user:manage', 'user:manage', 'user', 'manage', '', TRUE, 'user:manage' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'user:manage');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900033, 'cfg:read', 'cfg:read', 'cfg', 'read', '', FALSE, 'cfg:read' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'cfg:read');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900034, 'cfg:manage', 'cfg:manage', 'cfg', 'manage', '', TRUE, 'cfg:manage' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'cfg:manage');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900035, 'cfg:dict:manage', 'cfg:dict:manage', 'cfg', 'dict_manage', '', TRUE, 'cfg:dict:manage' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'cfg:dict:manage');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900036, 'audit:read', 'audit:read', 'audit', 'read', '', TRUE, 'audit:read' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'audit:read');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900037, 'audit:export', 'audit:export', 'audit', 'export', '', TRUE, 'audit:export' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'audit:export');
INSERT INTO sys_perms (id, code, name, domain, action, scope, is_sensitive, description) SELECT 900038, 'system:admin', 'system:admin', 'system', 'admin', '', TRUE, 'system:admin' WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'system:admin');

-- 内置角色
INSERT INTO sys_roles (id, code, name, is_builtin, description, max_data_level) SELECT 800001, 'owner', '所有者', TRUE, '内置角色，不可删除', 3 WHERE NOT EXISTS (SELECT 1 FROM sys_roles WHERE code = 'owner');
INSERT INTO sys_roles (id, code, name, is_builtin, description, max_data_level) SELECT 800002, 'curator', '代管人', TRUE, '内置角色，不可删除', 2 WHERE NOT EXISTS (SELECT 1 FROM sys_roles WHERE code = 'curator');
INSERT INTO sys_roles (id, code, name, is_builtin, description, max_data_level) SELECT 800003, 'family', '家庭成员', TRUE, '内置角色，不可删除', 2 WHERE NOT EXISTS (SELECT 1 FROM sys_roles WHERE code = 'family');
INSERT INTO sys_roles (id, code, name, is_builtin, description, max_data_level) SELECT 800004, 'org_admin', '机构管理员', TRUE, '内置角色，不可删除', 3 WHERE NOT EXISTS (SELECT 1 FROM sys_roles WHERE code = 'org_admin');
INSERT INTO sys_roles (id, code, name, is_builtin, description, max_data_level) SELECT 800005, 'auditor', '审计员', TRUE, '内置角色，不可删除', 1 WHERE NOT EXISTS (SELECT 1 FROM sys_roles WHERE code = 'auditor');

-- 角色-权限映射
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700001, 800001, 900001 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900001);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700002, 800001, 900002 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900002);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700003, 800001, 900003 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900003);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700004, 800001, 900004 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900004);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700005, 800001, 900005 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900005);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700006, 800001, 900006 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900006);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700007, 800001, 900007 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900007);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700008, 800001, 900008 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900008);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700009, 800001, 900009 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900009);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700010, 800001, 900010 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900010);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700011, 800001, 900011 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900011);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700012, 800001, 900012 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900012);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700013, 800001, 900013 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900013);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700014, 800001, 900014 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900014);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700015, 800001, 900015 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900015);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700016, 800001, 900016 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900016);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700017, 800001, 900017 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900017);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700018, 800001, 900018 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900018);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700019, 800001, 900019 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900019);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700020, 800001, 900020 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900020);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700021, 800001, 900021 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900021);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700022, 800001, 900022 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900022);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700023, 800001, 900023 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900023);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700024, 800001, 900024 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900024);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700025, 800001, 900025 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900025);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700026, 800001, 900026 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900026);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700027, 800001, 900027 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900027);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700028, 800001, 900028 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900028);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700029, 800001, 900029 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900029);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700030, 800002, 900001 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900001);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700031, 800002, 900003 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900003);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700032, 800002, 900005 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900005);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700033, 800002, 900007 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900007);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700034, 800002, 900011 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900011);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700035, 800002, 900013 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900013);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700036, 800002, 900015 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900015);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700037, 800002, 900017 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900017);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700038, 800002, 900019 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900019);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700039, 800002, 900021 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900021);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700040, 800002, 900024 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900024);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700041, 800002, 900025 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900025);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700042, 800002, 900026 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900026);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700043, 800002, 900027 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800002 AND perm_id = 900027);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700044, 800003, 900001 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800003 AND perm_id = 900001);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700045, 800003, 900011 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800003 AND perm_id = 900011);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700046, 800003, 900015 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800003 AND perm_id = 900015);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700047, 800003, 900019 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800003 AND perm_id = 900019);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700048, 800003, 900024 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800003 AND perm_id = 900024);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700049, 800003, 900026 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800003 AND perm_id = 900026);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700050, 800004, 900002 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900002);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700051, 800004, 900004 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900004);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700052, 800004, 900006 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900006);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700053, 800004, 900008 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900008);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700054, 800004, 900012 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900012);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700055, 800004, 900013 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900013);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700056, 800004, 900014 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900014);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700057, 800004, 900016 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900016);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700058, 800004, 900018 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900018);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700059, 800004, 900020 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900020);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700060, 800004, 900022 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900022);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700061, 800004, 900023 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900023);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700062, 800004, 900024 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900024);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700063, 800004, 900025 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900025);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700064, 800004, 900026 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900026);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700065, 800004, 900027 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900027);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700066, 800004, 900030 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900030);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700067, 800004, 900031 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900031);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700068, 800004, 900032 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900032);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700069, 800004, 900033 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900033);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700070, 800004, 900034 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900034);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700071, 800004, 900035 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900035);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700072, 800005, 900036 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800005 AND perm_id = 900036);
INSERT INTO sys_role_perms (id, role_id, perm_id) SELECT 700073, 800005, 900037 WHERE NOT EXISTS (SELECT 1 FROM sys_role_perms WHERE role_id = 800005 AND perm_id = 900037);
