/**
 * Copyright (c) [2022] Huawei Technologies Co., Ltd.
 * [opengauss-driver] is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2. 
 * You may obtain a copy of Mulan PSL v2 at:
 *            http://license.coscl.org.cn/MulanPSL2 
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, 
 * WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, 
 * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.  
 * See the Mulan PSL v2 for more details. 
 */
package cangjie_tpc::opengauss.collections

/**
 * @file
 *
 * Operation of stack data structure.
 */
internal import std.collection.*

/*
 * This class InnerStack
 * @author
 * @since 0.28.4
 */
public class StackIterator<T> <: Iterator<T> {
    private var myPosition: Int64 = -1
    private let myData: ArrayList<T>

    /*
     * The Function is init constructor
     *
     * @param data Initialization data
     *
     * @since 0.28.4
     */
    public init(data: ArrayList<T>) {
        myData = data
    }

    /*
     * Gets the value of the next index
     *
     * @return Option<T> Return value
     * @since 0.28.4
     */
    public func next(): Option<T> {
        myPosition++
        return myData.get(myPosition)
    }

}

/**
 * The class is InnerStack<T> inherited from Collection<T>
 * @author
 * @since 0.28.4
 */
public class InnerStack<T> <: Collection<T> {
    private var mySize: Int64 = 0
    private var myStack: ArrayList<T>
    let defaultCapacity: Int64 = 16

    /**
     * InnerStack initialization constructor
     *
     * @since 0.28.4
     */
    public init() {
        myStack = ArrayList<T>(defaultCapacity)
        mySize = 0
    }

    /**
     * InnerStack initialization constructor
     *
     * @param elements Initialization datas
     *
     * @since 0.28.4
     */
    public init(elements: Collection<T>) {
        myStack = ArrayList<T>(elements)
        mySize = elements.size
    }

    /**
     * InnerStack initialization constructor
     *
     * @param size Initialization datas size
     * @param elements Initialization datas
     *
     * @since 0.28.4
     */
    public init(size: Int64, initElement: (Int64) -> T) {
        myStack = ArrayList<T>(size, initElement)
        mySize = size
    }

    /**
     * InnerStack size
     *
     * @return Int64 Return stack value
     * @since 0.28.4
     */
    public override prop size: Int64 {
        get() {
            mySize
        }
    }

    /**
     * Judge whether the stack is empty
     *
     * @return Bool The return type of Bool
     * @since 0.28.4
     */
    public func isEmpty(): Bool {
        mySize == 0
    }

    /**
     * Get the top element of stack
     *
     *
     * @return Option<T> Return value
     * @since 0.28.4
     */
    public func peek(): Option<T> {
        myStack.get(mySize - 1)
    }

    /**
     * Remove last element
     *
     * @return Option<T> Return Remove element
     * @since 0.28.4
     */
    public func pop(): Option<T> {
        let ret = myStack.get(mySize - 1)
        myStack.remove(mySize - 1..mySize)
        mySize--
        ret
    }

    /**
     * Add an element to the end of the stack
     *
     * @param element Add element
     *
     * @return The return type of Unit
     * @since 0.28.4
     */
    public func push(element: T): Unit {
        myStack.add( element,at:mySize)
        mySize++
    }

    /**
     * Clone stack
     *
     * @return InnerStack<T> The return type of InnerStack<T>
     * @since 0.28.4
     */
    public func clone(): InnerStack<T> {
        return InnerStack<T>(this)
    }

    /**
     * InnerStack iterator
     *
     * @return Iterator<T> Return InnerStack<T>
     * @since 0.28.4
     */
    public func iterator(): Iterator<T> {
        return StackIterator<T>(this.myStack)
    }
}
