/*
 * @Author: LPY
 * @Date: 2025-06-03 09:29:03
 * @LastEditors: CU-Jon
 * @LastEditTime: 2025-09-27 03:16:38 EDT
 * @FilePath: \glkvm-cloud\web-ui\src\api\request.ts
 * @Description: 请求统一配置文件
 */
import { NotNeedHandledRequestErrorCodeList, RequestErrorCodeEnum } from '@/models/request'
import { useUserStore } from '@/stores/modules/user'
import { showErrorMessage } from './requestError'
import { BaseResponse, HttpService } from 'gl-web-main'
import type { AxiosResponse } from 'axios'

export const httpService = new HttpService(
    {timeout: 30000},
    config => {
        return config
    },
    // @ts-ignore
    response => {
        console.log(response)     
        // @ts-ignore
        const result:BaseResponse = {data: { code: 200, info: response.data } }
        return result  
        const code = response.data.code
        if (code === RequestErrorCodeEnum.INVALID_TOKEN 
            || code === RequestErrorCodeEnum.ACCOUNT_LOGIN_ELSEWHERE 
            || code === RequestErrorCodeEnum.INVALID_TOKEN_OLD_1
        ) {
            useUserStore().autoLogout()
            return Promise.reject(response.data)
        }

        if (code !== RequestErrorCodeEnum.SUCCESS) {
            if (!NotNeedHandledRequestErrorCodeList.includes(code)) {
                showErrorMessage(response.data)
            }
            return Promise.reject(response.data)
        }
        
        return response as AxiosResponse
    },
    error => {
        console.log('请求错误', error)
        return Promise.reject(error)
    },
)

export const { httpApiPrefixCloudBasic } = httpService
export default httpService.request