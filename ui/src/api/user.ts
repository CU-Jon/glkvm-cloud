/*
 * @Author: LPY
 * @Date: 2025-06-03 12:21:21
 * @LastEditors: CU-Jon
 * @LastEditTime: 2025-09-26 14:02:57 EDT
 * @FilePath: \glkvm-cloud\web-ui\src\api\user.ts
 * @Description: 用户相关请求api
 */

import request from './request'
import type { LoginParams, AuthConfig } from '@/models/user'

/** 登录 */
export function reqLogin (data: LoginParams) {
    return request<void>({
        url: '/signin',
        method: 'POST',
        data,
    })
}

/** 退出登录 */
export function reqLogout () {
    return request<void>({
        url: '/signout',
    })
}

/** 判断登录状态 */
export function reqCheckLoginStatus () {
    return request<void>({
        url: '/alive',
    })
}

/** 获取认证配置 */
export function reqAuthConfig () {
    return request<AuthConfig>({
        url: '/auth-config',
    })
}