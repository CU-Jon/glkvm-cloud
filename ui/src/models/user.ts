/*
 * @Author: LPY
 * @Date: 2025-06-09 16:37:00
 * @LastEditors: CU-Jon
 * @LastEditTime: 2025-09-26 14:02:57 EDT
 * @FilePath: \glkvm-cloud\web-ui\src\models\user.ts
 * @Description: 用户相关类型声明
 */

/** 登录参数 (Login parameters) */
export interface LoginParams {
    username?: string;
    password: string; 
    authMethod?: 'ldap' | 'legacy';
}

/** 认证配置 (Authentication configuration) */
export interface AuthConfig {
    ldapEnabled: boolean;
    legacyPassword: boolean;
}